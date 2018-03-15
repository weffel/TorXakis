{-# LANGUAGE OverloadedStrings #-}
module TorXakis.Parser
    ( ParsedDefs
    , adts
    , txsP
    , parseFile
    )
where

import           Text.ParserCombinators.Parsec.Language (haskell)
import qualified Data.Text as T
import           Data.Text (Text)
import           Text.Parsec ( ParsecT, (<|>), many, label, eof, unexpected, sepBy
                             , getPosition, sourceLine, sourceColumn
                             )
import           Text.Parsec.String (Parser)
import           Text.Parsec.Token ( lexeme, symbol
                                   , GenLanguageDef (LanguageDef), commentStart, commentEnd
                                   , commentLine
                                   , nestedComments, identStart, identLetter
                                   , opStart, opLetter, reservedNames, reservedOpNames
                                   , caseSensitive
                                   , GenTokenParser
                                   , makeTokenParser )
import           Text.Parsec.String (parseFromFile)
import           Text.Parsec.Char (lower, upper, oneOf, alphaNum, letter)
import           Data.List.NonEmpty (NonEmpty ((:|)))
import           Control.Arrow (left)
import           Control.Monad (void)
import           Control.Monad.State (State, put, get)
    
import           TorXakis.Sort.FieldDefs (FieldDef (FieldDef), FieldDefs, fieldDefs, emptyFieldDefs)
import           TorXakis.Sort.Name (Name, fromNonEmpty, getName, toText)
import           TorXakis.Sort.ADTDefs ( ADTDef (ADTDef), Unchecked, U (U)
                                       , Sort (SortInt, SortBool)
                                       )
import           TorXakis.Sort.ConstructorDefs ( ConstructorDef (ConstructorDef)
                                               , ConstructorDefs, constructorDefs)

import           TorXakis.Compiler.Error (Error)
import           TorXakis.Parser.Data    (St (St), nextId, FieldDecl, Field (Field), ParseTree (ParseTree)
                                         , Metadata (Metadata), SortRef (SortRef), OfSort)

parse :: String -> Either Error ParsedDefs
parse = undefined

parseFile :: FilePath -> IO (Either Error ParsedDefs)
parseFile fp =  left (T.pack . show) <$> parseFromFile txsP fp

-- | TorXakis definitions generated by the parser.
data ParsedDefs = ParsedDefs
    { adts  :: [UADTDef]
    , fdefs :: [UFuncDef]
    } deriving (Eq, Show)

-- | TorXakis top-level definitions
data TLDef = TLADT UADTDef
           | TLFun UFuncDef

asParsedDefs :: [TLDef] -> ParsedDefs
asParsedDefs ts = ParsedDefs as fs
    where (as, fs) = foldr sep ([], []) ts
          sep  (TLADT a) (xs, ys) = (a:xs, ys)
          sep  (TLFun f) (xs, ys) = (xs, f:ys)

topLevelDefP :: (a -> TLDef) -> Parser a -> Parser TLDef
topLevelDefP f p = f <$> p

txsP :: Parser ParsedDefs
txsP = do
    ts <- many $  fmap TLADT adtP
              <|> fmap TLFun fdefP
    eof
    return $ asParsedDefs ts

type UADTDef = ADTDef Unchecked

-- | Function definition.
data FuncDef sortRef = FuncDef
    { name :: Name, params :: FieldDefs sortRef, retType :: sortRef, body :: Exp}
    deriving (Eq, Show)

type UFuncDef = FuncDef Unchecked

-- | Expressions

data Exp = Var Name
    deriving (Eq, Show)

-- ** Sorts

sortP :: Parser Unchecked
sortP = do
    n <- txsLexeme (ucIdentifier "Sorts")
    case toText (getName n) of
        "Int"  -> return . U . Left  $ SortInt
        "Bool" -> return . U . Left  $ SortBool
        _      -> return . U . Right $ n

sortP' :: TxsParser OfSort
sortP' = do
    m <- getMetadata
    s <- txsLexeme' (ucIdentifier' "Sorts")
    return $ ParseTree s SortRef m ()

txsLexeme :: Parser a -> Parser a
txsLexeme = lexeme haskell

txsLexeme' :: TxsParser a -> TxsParser a
txsLexeme' = lexeme txsTokenP

txsSymbol' :: String -> TxsParser ()
txsSymbol' = void . symbol txsTokenP

txsSymbol :: String -> Parser ()
txsSymbol = void . symbol haskell

-- ** Fields

fieldListP :: Parser [UFieldDef]
fieldListP =  do
    fns <- txsLexeme lcIdentifier `sepBy` txsSymbol ","
    _  <- txsSymbol "::"
    fs <- sortP
    return $ mkFieldWithSort fs <$> fns
    where
      mkFieldWithSort fs fn = FieldDef fn fs md
          where md = ""

fieldListP' :: TxsParser [FieldDecl]
fieldListP' =  do
    fns <- txsLexeme' lcIdentifier' `sepBy` txsSymbol' ","
    _  <- txsSymbol' "::"
    fs <- sortP'
    traverse (mkFieldWithSort fs) fns
    where
      mkFieldWithSort :: OfSort -> Text -> TxsParser FieldDecl
      mkFieldWithSort fs fn = do
          m <- getMetadata
          return $ ParseTree fn Field m fs

lcIdentifier :: Parser Name
lcIdentifier = fromNonEmpty <$> identifierNE idStart
    where
      idStart = lower <|> oneOf "_"
                `label`
                "Identifiers must start with a lowercase character or '_'"

lcIdentifier' :: TxsParser Text
lcIdentifier' = identifierNE' idStart
    where
      idStart = lower <|> oneOf "_"
                `label`
                "Identifiers must start with a lowercase character or '_'"


ucIdentifier :: String -> Parser Name
ucIdentifier what  = fromNonEmpty <$> identifierNE idStart
    where
      idStart = upper
                `label`
                (what ++ " must start with an uppercase character")

ucIdentifier' :: String -> TxsParser Text
ucIdentifier' what  = identifierNE' idStart
    where
      idStart = upper
                `label`
                (what ++ " must start with an uppercase character")                

identifierNE :: Parser Char -> Parser (NonEmpty Char)
identifierNE idStart = (:|) <$> idStart <*> idEnd
    where
      idEnd  = many $
          alphaNum <|> oneOf "_"
          `label`
          "Identifiers must contain only alpha-numeric characters or '_'"

identifierNE' :: TxsParser Char -> TxsParser Text
identifierNE' idStart = T.cons <$> idStart <*> idEnd
    where
      idEnd  = T.pack <$> many (identLetter txsLangDef)

fieldsP :: String -- ^ Start symbol for the fields declaration.
        -> String -- ^ End symbol for the fields declaration.
        -> Parser (FieldDefs Unchecked)
fieldsP op cl = nonEmptyFieldsP <|> emptyFieldsP
    where nonEmptyFieldsP = do
              txsSymbol op
              fd <- aListOf fieldListP ";" (fieldDefs . concat)
              txsSymbol cl
              return fd
          emptyFieldsP = return emptyFieldDefs
    
type UFieldDef = FieldDef Unchecked

-- ** Constructors

cstrP :: Parser (ConstructorDef Unchecked)
cstrP = do
    cn <- txsLexeme (ucIdentifier "Constructors")
    fs <- "{" `fieldsP` "}"
    return $ ConstructorDef cn fs

cstrsP :: Parser (ConstructorDefs Unchecked)
cstrsP = aListOf cstrP "|" constructorDefs

-- | Parsing via smart constructors.
--
--
-- TODO: add some more details.
aListOf :: Show e
        => Parser a            -- ^ The parser for the items.
        -> String              -- ^ String used to separate the items.
        -> ([a] -> Either e b) -- ^ A smart constructor.
        -> Parser b
aListOf p sep f = do
    as <- p `sepBy` txsSymbol sep
    case f as of
        Left err -> unexpected $ show err
        Right val -> return val

-- ** ADT's

adtP :: Parser (ADTDef Unchecked)
adtP = do
    txsSymbol "TYPEDEF"
    an <- txsLexeme (ucIdentifier "ADT's")
    txsSymbol "::="
    cs <- cstrsP
    txsSymbol "ENDDEF"
    return $ ADTDef an cs

-- ** Function definitions

fdefP :: Parser UFuncDef
fdefP = do
    txsSymbol "FUNCDEF"
    n  <- txsLexeme lcIdentifier
    ps <- fParamsP
    txsSymbol "::"
    s  <- sortP
    txsSymbol "::="
    b <- txsLexeme fBodyP
    txsSymbol "ENDDEF"
    return $ FuncDef n ps s b

fParamsP :: Parser (FieldDefs Unchecked)
fParamsP = "(" `fieldsP` ")"

fBodyP :: Parser Exp
fBodyP =
    Var <$> lcIdentifier

fBodyP' :: TxsParser Exp
fBodyP' =
    Var <$> undefined 


-- * Parser with a custom monad.

type ParserInput = String

type TxsParser = ParsecT ParserInput St (State St)

txsLangDef :: GenLanguageDef ParserInput St (State St)
txsLangDef = LanguageDef
    { commentStart    = "{-"
    , commentEnd      = "-}"
    , commentLine     = "--"
    , nestedComments  = True
    , identStart      = letter
    , identLetter     = alphaNum <|> oneOf "_'"
    , opStart         = opLetter txsLangDef
    , opLetter        = oneOf ":!#$%&*+./<=>?@\\^|-~"
    , reservedNames   = ["TYPEDEF", "ENDDEF", "FUNCDEF"]
    , reservedOpNames = []
    , caseSensitive   = True
    }

txsTokenP :: GenTokenParser ParserInput St (State St)
txsTokenP = makeTokenParser txsLangDef

-- ** Utility functions

getMetadata :: TxsParser Metadata
getMetadata = do
    i <- getNextId
    p <- getPosition
    return $ Metadata (sourceLine p) (sourceColumn p) i

getNextId :: TxsParser Int
getNextId = do
    St i <- get
    put $ St (i + 1)
    return i
