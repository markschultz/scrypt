{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings,
    RecordWildCards, NamedFieldPuns #-}

-- |Scrypt is a sequential memory-hard key derivation function. This module
--  provides low-level bindings to the 'scrypt' key derivation function as
--  well as a higher-level password-storage API. It is based on a fast C
--  implementation of scrypt, written by Colin Percival. For further
--  information see <http://www.tarsnap.com/scrypt.html>.
--
module Crypto.Scrypt (
    -- * Parameters to the @scrypt@ function
    -- $params
     ScryptParams(..), scryptParams, defaultParams
    -- * Password Storage
    -- $password-storage
    , EncryptedPass(..), encryptPass, encryptPass', verifyPass, verifyPass'
    -- * Low-level bindings to the @scrypt@ key derivation function
    -- $low-level
    , Pass(..), Salt(..), PassHash(..), scrypt, scrypt'
    ) where

import Control.Applicative
import qualified Data.ByteString.Base64 as Base64
import Data.ByteString.Char8 hiding (map, concat)
import Data.Maybe
import Foreign (Ptr, Word8, Word32, Word64, allocaBytes, castPtr)
import Foreign.C
import System.Entropy (getEntropy)
import System.IO.Unsafe (unsafePerformIO)


newtype Pass          = Pass     { unPass :: ByteString } deriving (Show, Eq)
newtype Salt          = Salt     { unSalt :: ByteString } deriving (Show, Eq)
newtype PassHash      = PassHash { unHash :: ByteString } deriving (Show, Eq)
newtype EncryptedPass =
    EncryptedPass { unEncryptedPass  :: ByteString } deriving (Show, Eq)

------------------------------------------------------------------------------
-- $params
--
-- Scrypt takes three tuning parameters: @N@, @r@ and @p@. They affect running
-- time and memory usage:
--
-- /Memory usage/ is approximately @128*r*N@ bytes. Note that the
-- 'scryptParams' function takes @log_2(N)@ as a parameter. As an example,
-- the 'defaultParams'
--
-- >   log_2(N) = 14, r = 8 and p = 1
--
-- lead to 'scrypt' using @128 * 8 * 2^14 = 16M@ bytes of memory.
--
-- /Running time/ is proportional to all of @N@, @r@ and @p@. Since it's
-- influence on memory usage is small, @p@ can be used to independently tune
-- the running time.
--

-- |Encapsulates the three tuning parameters to the 'scrypt' function: @N@,
-- @r@ and @p@ (see above).
--
data ScryptParams = Params { logN, r, p, bufLen :: Integer} deriving (Eq)

instance Show ScryptParams where
    show Params{..} = concat [ "ScryptParams "
        , "{ logN=", show logN
        , ", r="   , show r
        , ", p="   , show p
        , ", buf="   , show bufLen
        , " }"
        ]

-- |Constructor function for the 'ScryptParams' data type
--
scryptParams
    :: Integer
    -- ^ @log_2(N)@. Scrypt's @N@ parameter must be a power of two greater
    --   than one, thus it's logarithm to base two must be greater than zero.
    --   @128*r*N@ must be smaller than the available memory address space.
    -> Integer
    -- ^ The parameter @r@, must be greater than zero.
    -> Integer
    -- ^ The parameter @p@, must be greater than zero. @r@ and @p@
    --   must satisfy @r*p < 2^30@.
    -> Maybe ScryptParams
    -- ^ Returns 'Just' the parameter object for valid arguments,
    --   otherwise 'Nothing'.
    --
scryptParams logN r p | valid     = Just ps
                      | otherwise = Nothing
  where
    ps    = Params { logN, r, p, bufLen = 64 }
    valid = and [ logN > 0, r > 0, p > 0
                , r*p < 2^(30 :: Int)
                , bufLen ps <= 2^(32 :: Int)-1 * 32
                -- allocation fits into (virtual) memory
                , 128*r*2^logN <= fromIntegral (maxBound :: CSize)
                ]

-- |Default parameters as recommended in the scrypt paper:
--
--  >   N = 2^14, r = 8, p = 1
--
--  Equivalent to @'fromJust' ('scryptParams' 14 8 1)@.
--
defaultParams :: ScryptParams
defaultParams = fromJust (scryptParams 14 8 1)

------------------------------------------------------------------------------
-- $password-storage
--
-- To allow storing encrypted passwords conveniently in a single database
-- column, the password storage API provides the data type 'EncryptedPass'. It
-- combines a 'Pass' as well as the 'Salt' and 'ScryptParams' used to compute
-- it into a single 'ByteString', separated by pipe (\"|\") characters. The
-- 'Salt' and 'PassHash' are base64-encoded. Storing the 'ScryptParams' with 
-- the password allows to gradually strengthen password encryption in case of
-- changing security requirements.
--
-- A usage example is given below, showing encryption, verification and
-- changing 'ScryptParams':
--
-- > >>> encrypted <- encryptPass defaultParams (Pass "secret")
-- > >>> print encrypted
-- > EncryptedPass {unEncryptedPass = "14|8|1|Wn5x[SNIP]nM=|Zl+p[SNIP]g=="}
-- > >>> print $ verifyPass defaultParams (Pass "secret") encrypted
-- > (True,Nothing)
-- > >>> print $ verifyPass defaultParams (Pass "wrong") encrypted
-- > (False,Nothing)
-- > >>> let newParams = fromJust $ scryptParams 16 8 1
-- > >>> print $ verifyPass newParams (Pass "secret") encrypted
-- > (True,Just (EncryptedPass {unEncryptedPass = "16|8|1|Wn5x[SNIP]nM=|ZmWw[SNIP]Q=="}))
--

combine :: ScryptParams -> Salt -> PassHash -> EncryptedPass
combine Params{..} (Salt salt) (PassHash passHash) =
    EncryptedPass $ intercalate "|"
        [ showBS logN, showBS r, showBS p
        , Base64.encode salt, Base64.encode passHash]
  where
    showBS = pack . show

separate :: EncryptedPass -> Maybe (ScryptParams, Salt, PassHash)
separate = go . split '|' . unEncryptedPass
  where
    go [logN', r', p', salt', hash'] = do
        [salt, hash] <- mapM decodeBase64 [salt', hash']
        [logN, r, p] <- mapM (fmap fst . readInteger) [logN', r', p']
        params       <- scryptParams logN r p
        return (params, Salt salt, PassHash hash)
    go _         = Nothing
    decodeBase64 = either (const Nothing) Just . Base64.decode

-- |Encrypt the password with the given parameters and a random 32-byte salt.
-- The salt is read from @\/dev\/urandom@ on Unix systems or @CryptoAPI@ on
-- Windows.
--
encryptPass :: ScryptParams -> Pass -> IO EncryptedPass
encryptPass params pass = do
    salt <- Salt <$> getEntropy 32
    return $ combine params salt (scrypt params salt pass)

-- |Equivalent to @encryptPass defaultParams@.
--
encryptPass' :: Pass -> IO EncryptedPass
encryptPass' = encryptPass defaultParams

-- |Verify a 'Pass' against an 'EncryptedPass'. The function also takes
--  'ScryptParams' meeting your current security requirements. In case the
--  'EncryptedPass' was generated with different parameters, the function
--  returns an updated 'EncryptedPass', generated with the given 
--  'ScryptParams'. The 'Salt' is kept from the given 'EncryptedPass'.
--
verifyPass
    :: ScryptParams
    -- ^ Parameters to use for updating the 'EncryptedPass'.
    -> Pass
    -- ^ The candidate 'Pass'.
    -> EncryptedPass
    -- ^ The 'EncryptedPass' to check against.
    -> (Bool, Maybe EncryptedPass)
    -- ^ Returns a pair of
    --
    --     * 'Bool' indicating verification success or failure.
    --
    --     * 'Just' a /new/ 'EncryptedPass' if the given 'ScryptParams' are
    --      different from those encapsulated in the /given/ 'EncryptedPass',
    --      otherwise 'Nothing'.
    --
verifyPass newParams candidate encrypted =
    maybe (False, Nothing) verify (separate encrypted)
  where
    verify (params,salt,hash) =
        let valid   = scrypt params salt candidate == hash
            newHash = scrypt newParams salt candidate
            newEncr = if not valid || params == newParams
                        then Nothing
                        else Just (combine newParams salt newHash)
        in (valid, newEncr)

-- |Check the 'Pass' against the 'EncryptedPass', using the 'ScryptParams'
--  encapsulated in the 'EncryptedPass'.
--
verifyPass' :: Pass -> EncryptedPass -> Bool
-- We never evaluate an eventual new 'EncryptedPass' from 'verifyPass', so it is
-- safe to pass 'undefined' to verifyPass.
verifyPass' pass encrypted = fst $ verifyPass undefined pass encrypted

------------------------------------------------------------------------------
-- $low-level
--
-- Bindings to a fast C implementation of 'scrypt'. For password storage,
-- consider using the more convenient higher-level API above.
--

-- |Calculates a 64-byte hash from the given password, salt and parameters.
--
scrypt :: ScryptParams -> Salt -> Pass -> PassHash
scrypt Params{..} (Salt salt) (Pass pass) =
    PassHash <$> unsafePerformIO $
        useAsCStringLen salt $ \(saltPtr, saltLen) ->
        useAsCStringLen pass $ \(passPtr, passLen) ->
        allocaBytes (fromIntegral bufLen) $ \bufPtr -> do
            throwErrnoIfMinus1_ "crypto_scrypt" $ crypto_scrypt
                (castPtr passPtr) (fromIntegral passLen)
                (castPtr saltPtr) (fromIntegral saltLen)
                (2^logN) (fromIntegral r) (fromIntegral p)
                bufPtr (fromIntegral bufLen)
            packCStringLen (castPtr bufPtr, fromIntegral bufLen)

foreign import ccall unsafe crypto_scrypt
    :: Ptr Word8 -> CSize         -- password
    -> Ptr Word8 -> CSize         -- salt
    -> Word64 -> Word32 -> Word32 -- N, r, p
    -> Ptr Word8 -> CSize         -- result buffer
    -> IO CInt

-- |Note the prime symbol (\'). Calls 'scrypt' with 'defaultParams'.
--
scrypt' :: Salt -> Pass -> PassHash
scrypt' = scrypt defaultParams
