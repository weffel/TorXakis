{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing -fno-warn-incomplete-patterns #-}
module TestConstraint
(
testConstraintList
)
where
-- general Haskell imports
import           Control.Monad.State
import           Data.Char
import qualified Data.Map            as Map
import           Data.Maybe
import           Data.Text           (Text)
import qualified Data.Text           as T
import           System.Process      (CreateProcess)
import           Text.Regex.TDFA

-- test specific Haskell imports
import           Test.HUnit

-- general Torxakis imports
import           ConstDefs
import           FreeMonoidX
import           FuncDef
import           FuncId
import           RegexXSD2Posix
import           Sort
import           ValExpr
import           VarId

-- specific SMT imports
import           SMT
import           SMTData
import           SolveDefs
import           TestSolvers


-- ----------------------------------------------------------------------------
smtSolvers :: [(String, CreateProcess)]
smtSolvers =  [ ("CVC4", cmdCVC4)
              , ("Z3", cmdZ3)
              ]

testConstraintList :: Test
testConstraintList =
    TestList $ concatMap (\(l,s) -> (map (\e -> TestLabel (l ++ " " ++ fst e) $ TestCase $ do smtEnv <- createSMTEnv s False
                                                                                              evalStateT (snd e) smtEnv )
                                         labelTestList
                                    )
                         )
                         smtSolvers

labelTestList :: [(String, SMT())]
labelTestList = [
        ("None",                                        testNone),
        ("Negative of Negative Is Identity",            testNegativeNegativeIsIdentity),
        ("Add Equal sum = e1 + e2",                     testAdd),
        ("No Variables",                                testNoVariables),
        ("Bool",                                        testBool),
        ("Bool False",                                  testBoolFalse),
        ("Bool True",                                   testBoolTrue),
        ("Int",                                         testInt),
        ("Int Negative",                                testIntNegative),
{-        ("Conditional Int Datatype",                    testConditionalInt),
        ("Conditional Int IsAbsent",                    testConditionalIntIsAbsent),
        ("Conditional Int IsPresent",                   testConditionalIntIsPresent),
        ("Conditional Int Present Value",               testConditionalIntPresentValue),
        ("Conditional Int Instances",                   testConditionalIntInstances),
        ("Nested Constructor",                          testNestedConstructor),
        ("Functions",                                   testFunctions), -}
        ("Just String",                                 testString)
        ]
    ++
       ioeTestStringEquals
    ++
        ioeTestStringLength
    ++
        ioeTestRegex

ioeTestStringEquals :: [(String, SMT())]
ioeTestStringEquals = [
        ("String Equals Empty",                     testStringEquals ""),
        ("String Equals Alphabet",                  testStringEquals "abcdefghijklmnopqrstuvwxyz"),
        ("String Equals SpecialChars",              testStringEquals "\a\t\n\r\0\x5E\126\127\128\xFF")
    ]
    ++ testStringEqualsChar

testStringEqualsChar :: [(String , SMT())]
testStringEqualsChar =
    map (\i -> ("char = " ++ [chr i], testStringEquals (T.pack [chr i])))  [0..255]

ioeTestStringLength :: [(String, SMT())]
ioeTestStringLength = [
        ("String Length    0",                     testStringLength    0),
        ("String Length   10",                     testStringLength   10),
        ("String Length  100",                     testStringLength  100),
        ("String Length 1000",                     testStringLength 1000)
    ]

ioeTestRegex :: [(String, SMT())]
ioeTestRegex = [
        ("Regex char",                      testRegex "X"),
        ("Regex concat chars",              testRegex "Jan"),
        ("Regex opt",                       testRegex "0?"),
        ("Regex plus",                      testRegex "a+"),
        ("Regex star",                      testRegex "b*"),
        ("Regex {n,m}",                     testRegex "c{3,5}"),
        ("Regex {n,}",                      testRegex "d{3,}"),
        ("Regex {n}",                       testRegex "r{3}"),
        ("Regex range",                     testRegex "[q-y]"),
        ("Regex 2 choices",                 testRegex "a|b"),
        ("Regex 3 choices",                 testRegex "a|b|c"),
        ("Regex group",                     testRegex "(a)"),
        ("Regex escape",                    testRegex "\\("),
        ("Regex escape operator",           testRegex "\\)+"),
        ("Regex escape range",              testRegex "\\|{2,4}"),
        ("Regex concat operator",           testRegex "ab+c*d?"),
        ("Regex mixed small",               testRegex "(ab+)|(p)"),
        ("Regex mixed large",               testRegex "(ab+c*d?)|(ef{2}g{3,6}h{3,})|(p)") -- bug reported https://ghc.haskell.org/trac/ghc/ticket/12974
    ]

-----------------------------------------------------
-- Helper function
-----------------------------------------------------
testTemplateSat :: [ValExpr VarId] -> SMT()
testTemplateSat createAssertions = do
    _ <- SMT.openSolver
    addAssertions createAssertions
    resp <- getSolvable
    lift $ assertEqual "sat" Sat resp
    SMT.close

testTemplateValue :: ADTDefs -> [Sort] -> ([VarId] -> [ValExpr VarId]) -> ([Const] -> SMT()) -> SMT()
testTemplateValue aDefs types createAssertions check = do
    _ <- SMT.openSolver
    addADTDefinitions aDefs
    let v = map (\(x,t) -> VarId (T.pack ("i" ++ show x)) x t) (zip [1000..] types)
    addDeclarations v
    addAssertions (createAssertions v)
    resp <- getSolvable
    lift $ assertEqual "sat" Sat resp
    sol <- getSolution v
    let mValues = map (`Map.lookup` sol) v
    lift $ assertBool "Is Just" (all isJust mValues)
    let values = map fromJust mValues
--    Trace.trace ("values = " ++ (show values)) $ do
    check values
    SMT.close

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

testNone :: SMT()
testNone = testTemplateSat []

testNegativeNegativeIsIdentity :: SMT()
testNegativeNegativeIsIdentity = testTemplateSat [cstrEqual ie (cstrUnaryMinus (cstrUnaryMinus ie))]
    where
        ie = cstrConst (Cint 3) :: ValExpr VarId

testAdd :: SMT()
testAdd = testTemplateSat [cstrEqual (cstrConst (Cint 12)) (cstrSum (fromListT [cstrConst (Cint 3), cstrConst (Cint 9)]))]

testNoVariables :: SMT()
testNoVariables = testTemplateValue emptyADTDefs [] (const []) check
    where
        check :: [Const] -> SMT()
        check [] = lift $ assertBool "expected pattern" True
        check _  = error "No variable in problem"

testBool :: SMT()
testBool = testTemplateValue emptyADTDefs [SortBool] (const []) check
    where
        check :: [Const] -> SMT()
        check [value]   = case value of
            Cbool _b -> lift $ assertBool "expected pattern" True
            _        -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"

testBoolTrue :: SMT()
testBoolTrue = testTemplateValue emptyADTDefs [SortBool] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrVar v]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value] = case value of
            Cbool b -> lift $ assertBool "expected pattern" b
            _       -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"

testBoolFalse :: SMT()
testBoolFalse = testTemplateValue emptyADTDefs [SortBool] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrNot (cstrVar v)]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value] = case value of
            Cbool b -> lift $ assertBool "expected pattern" (not b)
            _       -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"


testInt :: SMT()
testInt = testTemplateValue emptyADTDefs [SortInt] (const []) check
    where
        check :: [Const] -> SMT()
        check [value] = case value of
                            Cint _  -> lift $ assertBool "expected pattern" True
                            _       -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"



testIntNegative :: SMT()
testIntNegative = testTemplateValue emptyADTDefs [SortInt] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrLT (cstrVar v) (cstrConst (Cint 0))]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value]   = case value of
                            Cint x  -> lift $ assertBool ("expected pattern" ++ show x) (x < 0)
                            _       -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"

{-
conditionalIntSort :: Sort
conditionalIntSort = Sort "conditionalInt" 234

absentCstrId :: CstrId
absentCstrId = CstrId "_absent" 2345 [] conditionalIntSort

presentCstrId :: CstrId
presentCstrId = CstrId "_present" 2346 [SortInt] conditionalIntSort

isAbsentCstrFunc :: FuncId
isAbsentCstrFunc = FuncId "is_absent" 9876 [conditionalIntSort] SortBool

isPresentCstrFunc :: FuncId
isPresentCstrFunc = FuncId "is_present" 9877 [conditionalIntSort] SortBool

valuePresentCstrFunc :: FuncId
valuePresentCstrFunc = FuncId "value" 6565 [conditionalIntSort] SortInt
conditionalIntDef :: EnvDefs
conditionalIntDef = EnvDefs (Map.fromList [(conditionalIntSort, SortDef)]) (Map.fromList [(absentCstrId,CstrDef isAbsentCstrFunc []), (presentCstrId, CstrDef isPresentCstrFunc [valuePresentCstrFunc])]) Map.empty

testConditionalInt :: SMT()
testConditionalInt = testTemplateValue conditionalIntDef [conditionalIntSort] (const []) check
    where
        check :: [Const] -> SMT()
        check [value] = case value of
            Cstr x []       | x == absentCstrId  -> lift $ assertBool "expected pattern" True
            Cstr x [Cint _] | x == presentCstrId -> lift $ assertBool "expected pattern" True
            _                                    -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"


testConditionalIntIsAbsent :: SMT()
testConditionalIntIsAbsent = testTemplateValue conditionalIntDef [conditionalIntSort] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrIsCstr absentCstrId (cstrVar v)]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value]   = case value of
            Cstr x [] | x == absentCstrId  -> lift $ assertBool "expected pattern" True
            _                              -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"


testConditionalIntIsPresent :: SMT()
testConditionalIntIsPresent = testTemplateValue conditionalIntDef [conditionalIntSort] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrIsCstr presentCstrId (cstrVar v)]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value] = case value of
            Cstr x [Cint _] | x == presentCstrId    -> lift $ assertBool "expected pattern" True
            _                                       -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"


testConditionalIntPresentValue :: SMT()
testConditionalIntPresentValue = testTemplateValue conditionalIntDef [conditionalIntSort] createAssertions check
    where
        boundary :: Integer
        boundary = 4

        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v]    = [ cstrIsCstr presentCstrId (cstrVar v)
                                  , cstrITE (cstrIsCstr presentCstrId (cstrVar v))
                                            (cstrGT (cstrAccess presentCstrId 0 (cstrVar v)) (cstrConst (Cint boundary)) )
                                            (cstrConst (Cbool True))
                                  ]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value] = case value of
            Cstr c [Cint x] | c == presentCstrId    -> lift $ assertBool "expected pattern" (x > boundary)
            _                                       -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"


check3Different :: [Const] -> SMT()
check3Different [v1, v2, v3]    = do
                                    lift $ assertBool "value1 != value2" (v1 /= v2)
                                    lift $ assertBool "value1 != value3" (v1 /= v3)
                                    lift $ assertBool "value2 != value3" (v2 /= v3)
check3Different _               = error "Three variable in problem"

testConditionalIntInstances :: SMT()
testConditionalIntInstances = testTemplateValue conditionalIntDef
                                                [conditionalIntSort,conditionalIntSort,conditionalIntSort]
                                                createAssertions
                                                check3Different
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v1,v2,v3]    = [ cstrNot (cstrEqual (cstrVar v1) (cstrVar v2))
                                         , cstrNot (cstrEqual (cstrVar v2) (cstrVar v3))
                                         , cstrNot (cstrEqual (cstrVar v1) (cstrVar v3))
                                         ]
        createAssertions _   = error "Three variables in problem"


testNestedConstructor :: SMT()
testNestedConstructor = do
        let pairSort = Sort "Pair" 12345
        let pairCstrId = CstrId "Pair" 2344 [SortInt,SortInt] pairSort
        let absentCstrId = CstrId "Absent" 2345 [] conditionalPairSort
        let presentCstrId = CstrId "Present" 2346 [pairSort] conditionalPairSort
        let conditionalPairDefs = EnvDefs (Map.fromList [ (conditionalPairSort, SortDef), (pairSort, SortDef) ])
                                          (Map.fromList [ (pairCstrId, CstrDef (FuncId "ignore" 9875 [] pairSort) [FuncId "x" 6565 [] SortInt, FuncId "y" 6666 [] SortInt])
                                                        , (absentCstrId, CstrDef (FuncId "ignore" 9876 [] conditionalPairSort) [])
                                                        , (presentCstrId, CstrDef (FuncId "ignore" 9877 [] conditionalPairSort) [FuncId "value" 6767 [] pairSort])
                                                        ])        
                                          Map.empty

        testTemplateValue   conditionalPairDefs
                            [conditionalPairSort,conditionalPairSort,conditionalPairSort]
                            createAssertions
                            check3Different
    where
        conditionalPairSort = Sort "ConditionalPair" 9630

        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v1,v2,v3]    = [ cstrNot (cstrEqual (cstrVar v1) (cstrVar v2))
                                         , cstrNot (cstrEqual (cstrVar v2) (cstrVar v3))
                                         , cstrNot (cstrEqual (cstrVar v1) (cstrVar v3))
                                         ]
        createAssertions _   = error "Three variables in problem"

testFunctions :: SMT()
testFunctions = do
        let varX = VarId "x" 645421 SortBool
        let varY = VarId "y" 645422 SortBool
        let body1 = cstrEqual (cstrVar varX) (cstrVar varY)
        let fd1 = FuncDef [varX, varY] body1
        let fd2 = FuncDef [] const2

        let tDefs = EnvDefs Map.empty Map.empty (Map.fromList [(fid1, fd1), (fid2, fd2)])

        testTemplateValue tDefs
                          [SortBool,SortBool,SortInt]
                          createAssertions
                          check
    where
        fid1 = FuncId "multipleArgsFunction" 123454321 [SortBool, SortBool] SortBool
        fid2 = FuncId "myConst" 12345678 [] SortInt
        const2 = cstrConst (Cint 3) :: ValExpr VarId

        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [b1,b2,i]    = [ cstrFunc (Map.empty :: Map.Map FuncId (FuncDef VarId)) fid1 [cstrVar b1, cstrVar b2]
                                        , cstrEqual (cstrVar i) (cstrFunc (Map.empty :: Map.Map FuncId (FuncDef VarId)) fid2 [])
                                        ]
        createAssertions _   = error "Three variables in problem"

        check :: [Const] -> SMT()
        check [b1, b2, i] = do
                                lift $ assertEqual "booleans equal" b1 b2
                                lift $ assertEqual "i equal" const2  (cstrConst i)
        check _         = error "Three variable in problem"
-}

testString :: SMT()
testString = testTemplateValue emptyADTDefs [SortString] (const []) check
    where
        check :: [Const] -> SMT()
        check [value]   = case value of
                            Cstring _   -> lift $ assertBool "expected pattern" True
                            _           -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"

testStringEquals :: Text -> SMT()
testStringEquals str = testTemplateValue emptyADTDefs [SortString] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrEqual (cstrVar v) (cstrConst (Cstring str))]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value] = case value of
                            Cstring s   -> lift $ assertBool ("expected pattern s = " ++ T.unpack s)
                                                             (s == str)
                            _           -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"

testStringLength :: Int -> SMT()
testStringLength n = testTemplateValue emptyADTDefs [SortString] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrEqual (cstrConst (Cint (toInteger n))) (cstrLength (cstrVar v))]
        createAssertions _   = error "One variable in problem"

        check :: [Const] -> SMT()
        check [value] = case value of
                            Cstring s   -> lift $ assertBool "expected pattern" (n == T.length s)
                            _           -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"


testRegex :: String -> SMT ()
testRegex regexStr = testTemplateValue emptyADTDefs [SortString] createAssertions check
    where
        createAssertions :: [VarId] -> [ValExpr VarId]
        createAssertions [v] = [cstrStrInRe (cstrVar v) (cstrConst (Cregex (T.pack regexStr)))]
        
        check :: [Const] -> SMT()
        check [value] = case value of
                            Cstring s   -> let haskellRegex = xsd2posix . T.pack $ regexStr in
                                                lift $ assertBool ("expected pattern: smt solution " ++ T.unpack s ++ "\nXSD pattern " ++ regexStr ++ "\nHaskell pattern " ++ T.unpack haskellRegex)
                                                                  (T.unpack s =~ T.unpack haskellRegex)
                            _                  -> lift $ assertBool "unexpected pattern" False
        check _         = error "One variable in problem"