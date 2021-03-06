{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}

module ParseFunctionSig where

import Data.Void (Void)
import GHC.Generics
import Text.Megaparsec as M
import Text.Megaparsec.Error as M
import Text.Megaparsec.Char as M
import Text.Megaparsec.Char.Lexer as L

-- Examples:
-- - func: log10_(Tensor self) -> Tensor
-- - func: fft(Tensor self, int64_t signal_ndim, bool normalized=false) -> Tensor
-- - func: expand(Tensor self, IntList size, *, bool implicit=false) -> Tensor
-- - func: frobenius_norm_out(Tensor result, Tensor self, IntList[1] dim, bool keepdim=false) -> Tensor
-- - func: thnn_conv_dilated3d_forward(Tensor self, Tensor weight, IntList[3] kernel_size, Tensor? bias, IntList[3] stride, IntList[3] padding, IntList[3] dilation) -> (Tensor output, Tensor columns, Tensor ones)
-- - func: _cudnn_rnn_backward(Tensor input, TensorList weight, int64_t weight_stride0, Tensor weight_buf, Tensor hx, Tensor? cx, Tensor output, Tensor? grad_output, Tensor? grad_hy, Tensor? grad_cy, int64_t mode, int64_t hidden_size, int64_t num_layers, bool batch_first, double dropout, bool train, bool bidirectional, IntList batch_sizes, BoolTensor? dropout_state, Tensor reserve, std::array<bool,4> output_mask) -> (Tensor, Tensor, Tensor, TensorList)
-- - func: einsum(std::string equation, TensorList tensors) -> Tensor
-- - func: empty(IntList size, TensorOptions options={}) -> Tensor
-- - func: conv3d(Tensor input, Tensor weight, Tensor? bias={}, IntList[3] stride=1, IntList[3] padding=0, IntList[3] dilation=1, int64_t groups=1) -> Tensor

data DefaultValue =
    ValBool Bool
    | ValInt Int
    | ValDouble Double
    | ValDict
    | AtKLong
    | ReductionMean
    | NullPtr -- nullptr 
    | ValNone
    deriving Show

data Parameter  = Parameter {
    ptype :: Parsable
    , pname :: String
    , val :: Maybe DefaultValue
    } | Star  -- , *,  
    deriving Show

data Function  = Function {
    name :: String
    , parameters :: [Parameter]
    , retType :: Parsable
} deriving Show

data Parsable
    = Ptr Parsable
    | TenType TenType
    | DeviceType
    | GeneratorType
    | StorageType
    | CType CType
    | STLType STLType
    | CppString
    | Tuple [Parsable]
    deriving (Show, Generic)

data CType
    = CBool
    | CVoid
    | CDouble
    | CInt64
    | CInt64Q
    deriving (Eq, Show, Generic, Bounded, Enum)

data STLType
    = Array CType Int
    deriving (Show, Generic)

data TenType = Scalar
    | Tensor
    | TensorQ -- Tensor?
    | TensorOptions
    | TensorList
    | IndexTensor
    | BoolTensor
    | BoolTensorQ
    | IntList { dim :: Maybe [Int] }
    | ScalarQ
    | ScalarType
    | SparseTensorRef
    deriving Show

type Parser = Parsec Void String

defBool :: Parser DefaultValue
defBool = do
  val <- string "true" <|> string "false" <|> string "True" <|> string "False"
  pure $ if val == "true" || val == "True" then ValBool True else ValBool False

defInt :: Parser DefaultValue
defInt = do
  val <- pinteger
  pure $ ValInt (fromIntegral val)

defFloat :: Parser DefaultValue
defFloat = do
  val <- L.scientific
  pure $ ValDouble (realToFrac val)


-- defVal = do 
--     val <- L.float
--     pure (val :: Double)

-- Variants field

data Variants = VFunction | VMethod

-- variantsParser = do
--     string "variants:" 
--     val <- string ","
--     pure VNone

sc :: Parser ()
sc = L.space space1 empty empty

lexm :: Parser a -> Parser a
lexm = L.lexeme sc

parens :: Parser a -> Parser a
parens = between (string "(") (string ")")

pinteger :: Parser Integer
pinteger =
  (L.decimal) <|>
  ((string "-") >> L.decimal >>= \v -> pure (-v))

pfloat :: Parser Float
pfloat = L.float

rword :: String -> Parser ()
rword w = (lexm . try) (string w *> notFollowedBy alphaNumChar)

rws :: [String]
rws = []


identStart :: [Char]
identStart = ['a'..'z'] ++ ['A'..'Z'] ++ ['_']

identLetter :: [Char]
identLetter = ['a'..'z'] ++ ['A'..'Z'] ++ ['_'] ++ ['0'..'9'] ++ [':', '<', '>']


-- | parser of identifier
--
-- >>> parseTest identifier "fft"
-- "fft"
-- >>> parseTest identifier "_fft"
-- "_fft"
identifier :: Parser String
identifier = (lexm . try) (p >>= check)
 where
  p = (:) <$> (oneOf identStart) <*> many (oneOf identLetter)
  check x = if x `elem` rws
    then fail $ "keyword " ++ show x ++ " cannot be an identifier"
    else return x

-- | parser of identifier
--
-- >>> parseTest typ "BoolTensor"
-- TenType BoolTensor
-- >>> parseTest typ "BoolTensor?"
-- TenType BoolTensorQ
-- >>> parseTest typ "Device"
-- DeviceType
-- >>> parseTest typ "Generator*"
-- GeneratorType
-- >>> parseTest typ "IndexTensor"
-- TenType IndexTensor
-- >>> parseTest typ "IntList"
-- TenType (IntList {dim = Nothing})
-- >>> parseTest typ "IntList[1]"
-- TenType (IntList {dim = Just [1]})
-- >>> parseTest typ "Scalar"
-- TenType Scalar
-- >>> parseTest typ "Scalar?"
-- TenType ScalarQ
-- >>> parseTest typ "ScalarType"
-- TenType ScalarType
-- >>> parseTest typ "SparseTensorRef"
-- TenType SparseTensorRef
-- >>> parseTest typ "Storage"
-- StorageType
-- >>> parseTest typ "Tensor"
-- TenType Tensor
-- >>> parseTest typ "Tensor?"
-- TenType TensorQ
-- >>> parseTest typ "TensorList"
-- TenType TensorList
-- >>> parseTest typ "TensorOptions"
-- TenType TensorOptions
-- >>> parseTest typ "bool"
-- CType CBool
-- >>> parseTest typ "double"
-- CType CDouble
-- >>> parseTest typ "int64_t"
-- CType CInt64
-- >>> parseTest typ "int64_t?"
-- CType CInt64Q
-- >>> parseTest typ "std::array<bool,2>"
-- STLType (Array CBool 2)
-- >>> parseTest typ "std::string"
-- CppString
typ :: Parser Parsable
typ =
  tuple <|>
  idxtensor <|>
  booltensorq <|> booltensor <|>
  tensor <|>
  intlistDim <|> intlistNoDim <|>
  scalar <|>
  ctype <|>
  stl <|>
  cppstring <|>
  other
 where
  tuple = do
    lexm $ string "("
    val <- (sepBy typ (lexm (string ",")))
    lexm $ string ")"
    pure $ Tuple val
  other =
    ((lexm $ string "Device") >> (pure $ DeviceType)) <|>
    ((lexm $ string "Generator*") >> (pure $ GeneratorType)) <|>
    ((lexm $ string "Storage") >> (pure $ StorageType))
  scalar =
    ((lexm $ string "Scalar?") >> (pure $ TenType ScalarQ)) <|>
    ((lexm $ string "ScalarType") >> (pure $ TenType ScalarType)) <|>
    ((lexm $ string "Scalar") >> (pure $ TenType Scalar)) <|>
    ((lexm $ string "SparseTensorRef") >> (pure $ TenType SparseTensorRef))
  idxtensor = do
    lexm $ string "IndexTensor"
    pure $ TenType IndexTensor
  booltensor = do
    lexm $ string "BoolTensor"
    pure $ TenType BoolTensor
  booltensorq = do
    lexm $ string "BoolTensor?"
    pure $ TenType BoolTensorQ
  tensor =
    ((lexm $ string "TensorOptions") >> (pure $ TenType TensorOptions)) <|>
    ((lexm $ string "Tensor?") >> (pure $ TenType TensorQ)) <|>
    ((lexm $ string "TensorList") >> (pure $ TenType TensorList)) <|>
    ((lexm $ string "Tensor") >> (pure $ TenType Tensor))
  intlistDim = do
    lexm $ string "IntList["
    val <- (sepBy pinteger (lexm (string ",")))
    lexm $ string "]"
    pure $ TenType $ IntList (Just (map fromIntegral val))
  intlistNoDim = do
    lexm $ string "IntList"
    pure $ TenType $ IntList Nothing
  ctype =
    ((lexm $ string "bool") >> (pure $ CType CBool)) <|>
    ((lexm $ string "void") >> (pure $ CType CVoid)) <|>
    ((lexm $ string "double") >> (pure $ CType CDouble)) <|>
    ((lexm $ string "int64_t?") >> (pure $ CType CInt64Q)) <|>
    ((lexm $ string "int64_t") >> (pure $ CType CInt64))
  stl = do
    lexm $ string "std::array<"
    val <- ctype
    lexm $ string ","
    num <- pinteger
    lexm $ string ">"
    case val of
      CType v -> pure $ STLType $ Array v (fromIntegral num)
      _ -> fail "Can not parse ctype."
  cppstring = ((lexm $ string "std::string") >> (pure $ CppString))

-- | parser of defaultValue
--
-- >>> parseTest defaultValue "-100"
-- ValInt (-100)
-- >>> parseTest defaultValue "20"
-- ValInt 20
-- >>> parseTest defaultValue "0.125"
-- ValDouble 0.125
-- >>> parseTest defaultValue "1e-8"
-- ValDouble 1.0e-8
-- >>> parseTest defaultValue "False"
-- ValBool False
-- >>> parseTest defaultValue "None"
-- ValNone
-- >>> parseTest defaultValue "Reduction::Mean"
-- ReductionMean
-- >>> parseTest defaultValue "True"
-- ValBool True
-- >>> parseTest defaultValue "at::kLong"
-- AtKLong
-- >>> parseTest defaultValue "false"
-- ValBool False
-- >>> parseTest defaultValue "nullptr"
-- NullPtr
-- >>> parseTest defaultValue "true"
-- ValBool True
-- >>> parseTest defaultValue "{0,1}"
-- ValDict
-- >>> parseTest defaultValue "{}"
-- ValDict
defaultValue :: Parser DefaultValue
defaultValue =
  try floatp <|>
  try intp <|>
  defBool <|>
  nullp <|>
  nonep <|>
  reductionp <|>
  atklongp <|>
  dict <|>
  dict01
 where
   intp = do
     val <- lexm $ pinteger  :: Parser Integer
     pure $ ValInt (fromIntegral val)
   floatp = do
     v <- lexm $ L.float :: Parser Double
     pure $ ValDouble v
   nullp = do
     lexm $ string "nullptr"
     pure NullPtr
   reductionp = do
     lexm $ string "Reduction::Mean"
     pure ReductionMean
   atklongp = do
     lexm $ string "at::kLong"
     pure AtKLong
   dict = do
     lexm $ string "{}"
     pure ValDict
   dict01 = do
     lexm $ string "{0,1}"
     pure ValDict
   nonep = do
     lexm $ string "None"
     pure ValNone

-- | parser of argument
--
-- >>> parseTest arg "*"
-- Star
-- >>> parseTest arg "Tensor self"
-- Parameter {ptype = TenType Tensor, pname = "self", val = Nothing}
-- >>> Right v = parse (sepBy arg (lexm (string ","))) "" "Tensor self, Tensor self"
-- >>> map ptype v
-- [TenType Tensor,TenType Tensor]
-- >>> Right v = parse (sepBy arg (lexm (string ","))) "" "Tensor self, Tensor? self"
-- >>> map ptype v
-- [TenType Tensor,TenType TensorQ]
arg :: Parser Parameter
arg = star <|> param
 where
  param = do
    -- ptype <- lexm $ identifier
    ptype <- typ
    pname <- lexm $ identifier
    val   <- (do lexm (string "="); v <- defaultValue ; pure (Just v)) <|> (pure Nothing)
    pure $ Parameter ptype pname val
  star = do
    string "*"
    pure Star

-- | parser of argument
--
-- >>> parseTest rettype "Tensor"
-- TenType Tensor
-- >>> parseTest rettype "Tensor hoo"
-- TenType Tensor
-- >>> parseTest rettype "(Tensor hoo,Tensor bar)"
-- Tuple [TenType Tensor,TenType Tensor] 
rettype :: Parser Parsable
rettype = tuple <|> single
 where
  tuple = do
    lexm $ string "("
    val <- (sepBy rettype (lexm (string ",")))
    lexm $ string ")"
    pure $ Tuple val
  single = do
    type' <- typ
    _ <- ((do v <- lexm (identifier) ; pure (Just v)) <|> (pure Nothing))
    pure type'


-- | parser of function
--
-- >>> parseTest func "log10_(Tensor self) -> Tensor"
-- Function {name = "log10_", parameters = [Parameter {ptype = TenType Tensor, pname = "self", val = Nothing}], retType = TenType Tensor}
-- >>> parseTest func "fft(Tensor self, int64_t signal_ndim, bool normalized=false) -> Tensor"
-- Function {name = "fft", parameters = [Parameter {ptype = TenType Tensor, pname = "self", val = Nothing},Parameter {ptype = CType CInt64, pname = "signal_ndim", val = Nothing},Parameter {ptype = CType CBool, pname = "normalized", val = Just (ValBool False)}], retType = TenType Tensor}
-- >>> parseTest func "frobenius_norm_out(Tensor result, Tensor self, IntList[1] dim, bool keepdim=false) -> Tensor"
-- Function {name = "frobenius_norm_out", parameters = [Parameter {ptype = TenType Tensor, pname = "result", val = Nothing},Parameter {ptype = TenType Tensor, pname = "self", val = Nothing},Parameter {ptype = TenType (IntList {dim = Just [1]}), pname = "dim", val = Nothing},Parameter {ptype = CType CBool, pname = "keepdim", val = Just (ValBool False)}], retType = TenType Tensor}
-- >>> parseTest func "thnn_conv_dilated3d_forward(Tensor self, Tensor weight, IntList[3] kernel_size, Tensor? bias, IntList[3] stride, IntList[3] padding, IntList[3] dilation) -> (Tensor output, Tensor columns, Tensor ones)"
-- Function {name = "thnn_conv_dilated3d_forward", parameters = [Parameter {ptype = TenType Tensor, pname = "self", val = Nothing},Parameter {ptype = TenType Tensor, pname = "weight", val = Nothing},Parameter {ptype = TenType (IntList {dim = Just [3]}), pname = "kernel_size", val = Nothing},Parameter {ptype = TenType TensorQ, pname = "bias", val = Nothing},Parameter {ptype = TenType (IntList {dim = Just [3]}), pname = "stride", val = Nothing},Parameter {ptype = TenType (IntList {dim = Just [3]}), pname = "padding", val = Nothing},Parameter {ptype = TenType (IntList {dim = Just [3]}), pname = "dilation", val = Nothing}], retType = Tuple [TenType Tensor,TenType Tensor,TenType Tensor]}
func :: Parser Function
func = do
  fName <- identifier
  lexm $ string "("
  -- parse list of parameters
  args <- (sepBy arg (lexm (string ",")))
  lexm $ string ")"
  lexm $ string "->"
  retType <- rettype
  pure $ Function fName args retType

test = do
  --parseTest defBool "true"
  parseTest func "foo() -> Tensor"
  parseTest
    func
    "fft(Tensor self, int64_t signal_ndim, bool normalized=false) -> Tensor"
