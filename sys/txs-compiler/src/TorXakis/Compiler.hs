{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
module TorXakis.Compiler where

import           Control.Arrow                      (first, second, (&&&),
                                                     (|||))
import           Control.Lens                       (over, (^.), (^..))
import           Control.Monad                      (forM)
import           Control.Monad.Error.Class          (liftEither)
import           Control.Monad.State                (evalStateT, get)
import           Data.Data                          (Data)
import           Data.Data.Lens                     (uniplate)
import           Data.Map.Strict                    (Map)
import qualified Data.Map.Strict                    as Map
import           Data.Maybe                         (catMaybes, fromMaybe)
import           Data.Set                           (Set)
import qualified Data.Set                           as Set
import           Data.Text                          (Text)
import           Data.Tuple                         (swap)

import           BehExprDefs                        (Offer)
import           ChanId                             (ChanId)
import qualified ChanId
import           CstrId                             (CstrId)
import           FuncDef                            (FuncDef (FuncDef))
import           FuncId                             (FuncId (FuncId), name)
import qualified FuncId
import           FuncTable                          (FuncTable, Handler,
                                                     Signature (Signature),
                                                     toMap)
import           Id                                 (Id (Id), _id)
import           Sigs                               (Sigs, chan, func, pro,
                                                     sort, uniqueCombine)
import qualified Sigs                               (empty)
import           SortId                             (SortId, sortIdBool,
                                                     sortIdInt, sortIdRegex,
                                                     sortIdString)
import           StdTDefs                           (chanIdIstep, stdFuncTable,
                                                     stdTDefs)
import           TxsDefs                            (BExpr, ProcDef, ProcId,
                                                     TxsDefs, chanid, cnectDefs,
                                                     fromList, funcDefs,
                                                     mapperDefs, modelDefs,
                                                     procDefs, purpDefs, union)
import qualified TxsDefs                            (empty)
import           ValExpr                            (ValExpr,
                                                     ValExprView (Vfunc, Vite),
                                                     cstrITE, cstrVar, view)
import           VarId                              (VarId, varsort)
import qualified VarId

import           TorXakis.Compiler.Data
import           TorXakis.Compiler.Defs.ChanId
import           TorXakis.Compiler.Defs.ProcDef
import           TorXakis.Compiler.Defs.Sigs
import           TorXakis.Compiler.Defs.TxsDefs
import           TorXakis.Compiler.Error            (Error)
import           TorXakis.Compiler.Maps
import           TorXakis.Compiler.Maps.DefinesAMap
import           TorXakis.Compiler.MapsTo
import           TorXakis.Compiler.Simplifiable
import           TorXakis.Compiler.ValExpr.Common
import           TorXakis.Compiler.ValExpr.CstrId
import           TorXakis.Compiler.ValExpr.ExpDecl
import           TorXakis.Compiler.ValExpr.FuncDef
import           TorXakis.Compiler.ValExpr.FuncId
import           TorXakis.Compiler.ValExpr.SortId
import           TorXakis.Compiler.ValExpr.ValExpr
import           TorXakis.Compiler.ValExpr.VarId

import           TorXakis.Compiler.Data.ProcDecl
import           TorXakis.Compiler.Defs.BehExprDefs
import           TorXakis.Compiler.Defs.FuncTable
import           TorXakis.Compiler.Maps.VarRef
import           TorXakis.Parser
import           TorXakis.Parser.BExpDecl
import           TorXakis.Parser.Common             (TxsParser)
import           TorXakis.Parser.Data
import           TorXakis.Parser.ValExprDecl

-- | Compile a string into a TorXakis model.
--
compileFile :: FilePath -> IO (Either Error (Id, TxsDefs, Sigs VarId))
compileFile fp = do
    ePd <- parseFile fp
    case ePd of
        Left err -> return . Left $ err
        Right pd -> return $
            evalStateT (runCompiler . compileParsedDefs $ pd) newState


compileUnsafe :: CompilerM a -> a
compileUnsafe cmp = throwOnError $
    evalStateT (runCompiler cmp) newState

-- | Legacy compile function, used to comply with the old interface. It should
-- be deprecated in favor of @compile@.
compileLegacy :: String -> (Id, TxsDefs, Sigs VarId)
compileLegacy str =
    case parseString "" str of
        Left err -> error $ show err
        Right pd ->
            compileUnsafe (compileParsedDefs pd)

throwOnError :: Either Error a -> a
throwOnError = throwOnLeft ||| id
    where throwOnLeft = error . show

compileParsedDefs :: ParsedDefs -> CompilerM (Id, TxsDefs, Sigs VarId)
compileParsedDefs pd = do
    sIds <- compileToSortIds pd
    cstrIds <- compileToCstrId sIds (pd ^. adts)

    stdFuncIds <- Map.fromList <$> getStdFuncIds
    cstrFuncIds <- Map.fromList <$> adtsToFuncIds sIds (pd ^. adts)
    fIds <- Map.fromList <$> funcDeclsToFuncIds sIds (allFuncs pd)
    let
        allFids = stdFuncIds `Map.union` cstrFuncIds `Map.union` fIds
        lfDefs = compileToFuncLocs allFids

    decls <- compileToDecls lfDefs pd
    -- Infer the types of all variable declarations.
    let emptyVdMap = Map.empty :: Map (Loc VarDeclE) SortId
    -- We pass to 'inferTypes' an empty map from 'Loc VarDeclE' to 'SortId'
    -- since no variables can be declared at the top level.
    let allFSigs = funcIdAsSignature <$> allFids
    vdSortMap <- inferTypes (sIds :& decls :& allFSigs :& emptyVdMap) (allFuncs pd)
    -- Construct the variable declarations to @VarId@'s lookup table.
    vIds <- generateVarIds vdSortMap (allFuncs pd)

    --
    -- UNDER REFACTOR!
    --

    adtsFt <- adtsToFuncTable (sIds :& cstrIds) (pd ^. adts)
    stdSHs <- fLocToSignatureHandlers stdFuncIds stdFuncTable
    adtsSHs <- fLocToSignatureHandlers cstrFuncIds adtsFt
    -- TODO: The @FuncDef@s are only required by the @toTxsDefs@, so it makes sense to
    -- split @funcDeclsToFuncDefs2@ into:
    --
    -- - 'funcDeclsToSignatureHandlers'
    -- - 'funcDeclsToFuncDefs' (to be used at @toTxsDefs@)
    fSHs <- Map.fromList <$> traverse (funcDeclToSH allFids) (allFuncs pd)

    fdefs <- funcDeclsToFuncDefs2 (vIds :& allFids :& decls)
                                  (stdSHs `Map.union` adtsSHs `Map.union` fSHs)
                                  (allFuncs pd)
    let fdefsSHs = innerSigHandlerMap (fIds :& fdefs)
        allFSHs = stdSHs `Map.union` adtsSHs `Map.union` fdefsSHs

    --
    -- UNDER REFACTOR!
    --
    pdefs <- compileToProcDefs (sIds :& cstrIds :& allFids :& allFSHs :& decls) pd
    chIds <- getMap sIds (pd ^. chdecls) :: CompilerM (Map (Loc ChanDeclE) ChanId)
    let mm = sIds :& pdefs :& cstrIds :& allFids :& fdefs
    sigs    <- toSigs (mm :& chIds) pd
    -- We need the map from channel names to the locations in which these
    -- channels are declared, because the model definitions rely on channels
    -- declared outside its scope.
    chNames <-  getMap () (pd ^. chdecls) :: CompilerM (Map Text (Loc ChanDeclE))
    txsDefs <- toTxsDefs (func sigs) (mm :& decls :& vIds :& vdSortMap :& chNames :& chIds :& allFSHs) pd
    St i    <- get
    return (Id i, txsDefs, sigs)

toTxsDefs :: ( MapsTo Text        SortId mm
             , MapsTo (Loc CstrE) CstrId mm
             , MapsTo (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]) mm
             , MapsTo (Loc FuncDeclE) (Signature, Handler VarId) mm
             , MapsTo (Loc FuncDeclE) FuncId mm
             , MapsTo FuncId FuncDefInfo mm
             , MapsTo ProcId ProcDef mm
             , MapsTo Text (Loc ChanDeclE) mm
             , MapsTo (Loc ChanDeclE) ChanId mm
             , MapsTo (Loc VarDeclE) VarId mm
             , MapsTo (Loc VarDeclE) SortId mm
             , In (Loc FuncDeclE, Signature) (Contents mm) ~ 'False
             , In (Loc ChanRefE, Loc ChanDeclE) (Contents mm) ~ 'False
             , In (ProcId, ()) (Contents mm) ~ 'False )
          => FuncTable VarId -> mm -> ParsedDefs -> CompilerM TxsDefs
toTxsDefs ft mm pd = do
    ads <- adtsToTxsDefs mm (pd ^. adts)
    -- Get the function id's of all the constants.
    cfIds <- traverse (mm .@) (pd ^.. consts . traverse . loc')
    let
        fdiMap :: Map FuncId FuncDefInfo
        fdiMap = innerMap mm
        fdefMap :: Map FuncId (FuncDef VarId)
        fdefMap = funcDef <$> fdiMap
        -- TODO: we have to remove the constants to comply with what TorXakis generates :/
        funcDefsNoConsts = Map.withoutKeys fdefMap (Set.fromList cfIds)
        -- TODO: we have to simplify to comply with what TorXakis generates.
        fn = idefsNames mm ++ fmap name cfIds
        fds = TxsDefs.empty {
            funcDefs = simplify ft fn funcDefsNoConsts
            }
        pds = TxsDefs.empty {
            procDefs = simplify ft fn (innerMap mm)
            }
    -- TODO: why not have these functions return a TxsDef data directly.
    -- Simplify this boilerplate!
    mDefMap <- modelDeclsToTxsDefs mm (pd ^. models)
    let mds = TxsDefs.empty { modelDefs = simplify ft fn mDefMap }
    uDefMap <- purpDeclsToTxsDefs mm (pd ^. purps)
    let uds = TxsDefs.empty { purpDefs = simplify ft fn uDefMap }
    cDefMap <- cnectDeclsToTxsDefs mm (pd ^. cnects)
    let cds = TxsDefs.empty { cnectDefs = simplify ft fn cDefMap }
    rDefMap <- mapperDeclsToTxsDefs mm (pd ^. mappers)
    let rds = TxsDefs.empty { mapperDefs = simplify ft fn rDefMap }
    return $ ads
        `union` fds
        `union` pds
        `union` fromList stdTDefs
        `union` mds
        `union` uds
        `union` cds
        `union` rds

toSigs :: ( MapsTo Text        SortId mm
          , MapsTo (Loc CstrE) CstrId mm
          , MapsTo (Loc FuncDeclE) FuncId mm
          , MapsTo FuncId FuncDefInfo mm
          , MapsTo ProcId ProcDef mm
          , MapsTo (Loc ChanDeclE) ChanId mm)
       => mm -> ParsedDefs -> CompilerM (Sigs VarId)
toSigs mm pd = do
    let ts   = sortsToSigs (innerMap mm)
    as  <- adtDeclsToSigs mm (pd ^. adts)
    fs  <- funDeclsToSigs mm (pd ^. funcs)
    cs  <- funDeclsToSigs mm (pd ^. consts)
    let pidMap :: Map ProcId ProcDef
        pidMap = innerMap mm
        ss = Sigs.empty { func = stdFuncTable
                        , chan = values @(Loc ChanDeclE) mm
                        , pro  = Map.keys pidMap
                        }
    return $ ts `uniqueCombine` as
        `uniqueCombine` fs
        `uniqueCombine` cs
        `uniqueCombine` ss

funcDefInfoNamesMap :: [Loc FuncDeclE] -> Map Text [Loc FuncDeclE]
funcDefInfoNamesMap fdis =
    groupByName $ catMaybes $ asPair <$> fdis
    where
      asPair :: Loc FuncDeclE -> Maybe (Text, Loc FuncDeclE)
      asPair fdi = (, fdi) <$> fdiName fdi
      groupByName :: [(Text, Loc FuncDeclE)] -> Map Text [Loc FuncDeclE]
      groupByName = Map.fromListWith (++) . fmap (second pure)

-- | Get a dictionary from sort names to their @SortId@. The sorts returned
-- include all the sorts defined by a 'TYPEDEF' (in the parsed definitions),
-- and the predefined sorts ('Bool', 'Int', 'Regex', 'String').
compileToSortIds :: ParsedDefs -> CompilerM (Map Text SortId)
compileToSortIds pd = do
    -- Construct the @SortId@'s lookup table.
    sMap <- compileToSortId (pd ^. adts)
    let pdsMap = Map.fromList [ ("Bool", sortIdBool)
                              , ("Int", sortIdInt)
                              , ("Regex", sortIdRegex)
                              , ("String", sortIdString)
                              ]
    return $ Map.union pdsMap sMap

-- | Get all the functions in the parsed definitions.
allFuncs :: ParsedDefs -> [FuncDecl]
allFuncs pd = pd ^. funcs ++ pd ^. consts

-- | Get a dictionary from the function names to the locations in which these
-- functions are defined.
--
compileToFuncLocs :: Map (Loc FuncDeclE) FuncId -> Map Text [Loc FuncDeclE]
compileToFuncLocs fIds = Map.fromListWith (++) $
    fmap mkPair (Map.toList fIds)
    where
      mkPair :: (Loc FuncDeclE, FuncId) -> (Text, [Loc FuncDeclE])
      mkPair (fdi, fId) = (name fId, [fdi])

-- | Get a dictionary from variable references to the possible location in
-- which these variables are declared. Due to overloading a syntactic reference
-- to a variable can refer to a variable, or multiple functions.
compileToDecls :: Map Text [Loc FuncDeclE]
               -> ParsedDefs
               -> CompilerM (Map (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]))
compileToDecls lfDefs pd = do
    let eVdMap = Map.empty :: Map Text (Loc VarDeclE)
    fRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (allFuncs pd)
    pRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. procs)
    sRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. stauts)
    mRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. models)
    uRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. purps)
    cRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. cnects)
    rRtoDs <- Map.fromList <$> mapRefToDecls (eVdMap :& lfDefs) (pd ^. mappers)
    return $ fRtoDs `Map.union` pRtoDs `Map.union` sRtoDs `Map.union` mRtoDs
            `Map.union` uRtoDs `Map.union` cRtoDs `Map.union` rRtoDs

-- | Generate the map from process id's definitions to process definitions.
compileToProcDefs :: ( MapsTo Text SortId mm
                     , MapsTo (Loc FuncDeclE) (Signature, Handler VarId) mm
                     , MapsTo (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE]) mm
                     , In (Loc FuncDeclE, Signature) (Contents mm) ~ 'False
                     , In (Loc ChanDeclE, ChanId) (Contents mm) ~ 'False
                     , In (Loc VarDeclE, VarId) (Contents mm) ~ 'False
                     , In (Text, ChanId) (Contents mm) ~ 'False
                     , In (Loc ProcDeclE, ProcInfo) (Contents mm) ~ 'False
                     , In (Loc ChanRefE, Loc ChanDeclE) (Contents mm) ~ 'False
                     , In (ProcId, ()) (Contents mm) ~ 'False
                     , In (Loc VarDeclE, SortId) (Contents mm) ~ 'False)
                  => mm -> ParsedDefs -> CompilerM (Map ProcId ProcDef)
compileToProcDefs mm pd = do
    pmsP <- getMap mm (pd ^. procs)  :: CompilerM (Map (Loc ProcDeclE) ProcInfo)
    pmsS <- getMap mm (pd ^. stauts) :: CompilerM (Map (Loc ProcDeclE) ProcInfo)
    let pms = pmsP `Map.union` pmsS -- TODO: we might consider detecting for duplicated process here.
    procPDefMap  <- procDeclsToProcDefMap (pms :& mm) (pd ^. procs)
    stautPDefMap <- stautDeclsToProcDefMap (pms :& mm) (pd ^. stauts)
    return $ procPDefMap `Map.union` stautPDefMap

-- * External parsing functions

-- | Compiler for value definitions
--
-- name valdefsParser   ExNeValueDefs     -- valdefsParser   :: [Token]
--
-- Originally:
--
-- > SIGS VARENV UNID -> ( Int, VEnv )
--
-- Where
--
-- > SIGS   ~~ (Sigs VarId)
-- > VARENV ~~ [VarId]  WARNING!!!!! This thing is empty when used at the server, so we might not need it.
-- > UNID   ~~ Int
valdefsParser :: Sigs VarId
              -> [VarId]
              -> Int
              -> String
              -> CompilerM (Id, Map VarId (ValExpr VarId))
valdefsParser sigs vids unid str = do
    ls <- liftEither $ parse 0 "" str letVarDeclsP
    setUnid unid

    --
    -- TODO: factor out duplication w.r.t @vexprParser@
    --

    let
        vlocs :: [(Loc VarDeclE, VarId)]
        vlocs = zip (varIdToLoc <$> vids) vids

        text2vdloc :: Map Text (Loc VarDeclE)
        text2vdloc = Map.fromList $
                     zip (VarId.name . snd <$> vlocs) (fst <$> vlocs)

        text2sh :: [(Text, (Signature, Handler VarId))]
        text2sh = do
            (t, shmap) <- Map.toList . toMap . func $ sigs
            (s, h) <- Map.toList shmap
            return (t, (s, h))


    floc2sh <- forM text2sh $ \(t, (s, h)) -> do
        i <- getNextId
        return (PredefLoc t i, (s, h))

    let
        text2fdloc :: Map Text [Loc FuncDeclE]
        text2fdloc = Map.fromListWith (++) $
            zip (fst <$> text2sh) (pure . fst <$> floc2sh)
        tsids :: Map Text SortId
        tsids = sort sigs
        vsids :: Map (Loc VarDeclE) SortId
        vsids = Map.fromList . fmap (second varsort) $ vlocs
        fsigs :: Map (Loc FuncDeclE) Signature
        fsigs = Map.fromList $ fmap (second fst) floc2sh

    vdecls <- Map.fromList <$> mapRefToDecls (text2vdloc :& text2fdloc) ls
    let  mm = tsids :& vsids :& fsigs :& vdecls
    vsids' <- Map.fromList <$> inferVarTypes mm ls
    vvids  <- Map.fromList <$> mkVarIds (vsids' <.+> vsids) ls
    let mm' = vdecls
            :& vvids
            :& Map.fromList floc2sh

    --
    -- TODO: factor out duplication w.r.t @vexprParser@
    --

    vrvds <- liftEither $ varDefsFromExp mm' ls

    venv <- liftEither $ parValDeclToMap vrvds ls

    unid'  <- getUnid
    return (Id unid', venv)

mkFuncDecls :: [FuncId] -> Map Text [Loc FuncDeclE]
mkFuncDecls fs = Map.fromListWith (++) $ zip (FuncId.name <$> fs)
                                             (pure . fIdToLoc <$> fs)

mkFuncIds :: [FuncId] -> Map (Loc FuncDeclE) FuncId
mkFuncIds fs = Map.fromList $ zip (fIdToLoc <$> fs) fs

-- | Sub-compiler for value expressions.
--
vexprParser :: Sigs VarId
            -> [VarId]
            -> Int
            -> String                        -- ^ String to parse.
            -> CompilerM (Id, ValExpr VarId)
vexprParser sigs vids unid str =
    subCompile sigs [] vids unid str valExpP $ \scm eDecl -> do

        let mm =  text2sidM scm
               :& lvd2sidM scm
               :& lfd2sgM scm
               :& lvr2lvdOrlfdM scm
        eSid  <- liftEither $ inferExpTypes mm eDecl >>= getUniqueElement
        liftEither $ expDeclToValExpr (lvr2vidOrsghdM scm) eSid eDecl

fIdToLoc :: FuncId -> Loc FuncDeclE
fIdToLoc fId = PredefLoc (FuncId.name fId) (_id . FuncId.unid $ fId)

-- TODO: consider renaming these functions to vid2loc (be consistent!).
varIdToLoc :: VarId -> Loc VarDeclE
varIdToLoc vId = PredefLoc (VarId.name vId) (_id . VarId.unid $ vId)

chIdToLoc :: ChanId -> Loc ChanDeclE
chIdToLoc chId = PredefLoc (ChanId.name chId) (_id . ChanId.unid $ chId)

-- | Sub-compiler for behavior expressions.
bexprParser :: Sigs VarId
            -> [ChanId]
            -> [VarId]
            -> Int
            -> String
            -> CompilerM (Id, BExpr)
bexprParser sigs chids vids unid str = do
    bDecl <- liftEither $ parse 0 "" str bexpDeclP
    setUnid unid

    -- These additional maps are needed w.r.t. @vexprParser@
    let
        cd2chids :: Map (Loc ChanDeclE) ChanId
        cd2chids = Map.fromList $ zip (chIdToLoc <$> chids) chids

        text2chids :: Map Text (Loc ChanDeclE)
        text2chids = Map.fromList $ zip (ChanId.name <$> chids) (chIdToLoc <$> chids)

        procIds :: Map ProcId ()
        procIds = Map.fromList $ zip (pro sigs) (repeat ())

    chDecls <- getMap text2chids bDecl  :: CompilerM (Map (Loc ChanRefE) (Loc ChanDeclE))
    --
    -- TODO: factor out duplication w.r.t. @vexprParser@
    --

    let
        vlocs :: [(Loc VarDeclE, VarId)]
        vlocs = zip (varIdToLoc <$> vids) vids

        text2vdloc :: Map Text (Loc VarDeclE)
        text2vdloc = Map.fromList $
                     zip (VarId.name . snd <$> vlocs) (fst <$> vlocs)

        text2sh :: [(Text, (Signature, Handler VarId))]
        text2sh = do
            (t, shmap) <- Map.toList . toMap . func $ sigs
            (s, h) <- Map.toList shmap
            return (t, (s, h))


    floc2sh <- forM text2sh $ \(t, (s, h)) -> do
        i <- getNextId
        return (PredefLoc t i, (s, h))

    let
        text2fdloc :: Map Text [Loc FuncDeclE]
        text2fdloc = Map.fromListWith (++) $
            zip (fst <$> text2sh) (pure . fst <$> floc2sh)
        tsids :: Map Text SortId
        tsids = sort sigs
        vsids :: Map (Loc VarDeclE) SortId
        vsids = Map.fromList . fmap (second varsort) $ vlocs
        fsigs :: Map (Loc FuncDeclE) Signature
        fsigs = Map.fromList $ fmap (second fst) floc2sh

    vdecls <- Map.fromList <$> mapRefToDecls (text2vdloc :& text2fdloc) bDecl
    let  mm = tsids :& vsids :& fsigs :& vdecls
             :& (chDecls :& cd2chids :& procIds)  -- Differences w.r.t. @vexprParser@.
    vsids' <- Map.fromList <$> inferVarTypes mm bDecl
    vvids  <- Map.fromList <$> mkVarIds (vsids' <.+> vsids) bDecl
    let mm' = vdecls
            :& vvids
            :& Map.fromList floc2sh

    --
    -- TODO: factor out duplication w.r.t @vexprParser@
    --

    vrvds <- liftEither $ varDefsFromExp mm' bDecl
    let mm'' = tsids :& vsids :& vdecls
             :& (chDecls :& cd2chids :& procIds)
             :& Map.fromList floc2sh
    bExp <- toBExpr mm'' vrvds bDecl

    unid' <- getUnid
    return (Id unid', bExp)

prefoffsParser :: Sigs VarId
            -> [ChanId]
            -> [VarId]
            -> Int
            -> String
            -> CompilerM (Id, Set Offer)
prefoffsParser sigs chids vids unid str =
    subCompile sigs chids vids unid str offersP $ \scm ofsDecl -> do
        let mm = text2sidM scm
                :& lvr2lvdOrlfdM scm
                :& lvd2sidM scm
                :& lfd2sghdM scm
                :& lchr2lchdM scm
                :& lchd2chidM scm

        os <- traverse (toOffer mm (lvr2vidOrsghdM scm)) ofsDecl
        -- Filter the internal actions (to comply with the current TorXakis compiler).
        return $ Set.fromList $ filter ((chanIdIstep /=) . chanid) os

-- | Maps required for the sub-compilation functions.
data SubCompileMaps = SubCompileMaps
    { text2sidM :: Map Text SortId
    , lvd2sidM  :: Map (Loc VarDeclE) SortId
    , lvd2vidM  :: Map (Loc VarDeclE) VarId
    , text2lfdM :: Map Text [Loc FuncDeclE]
    , lfd2sgM   :: Map (Loc FuncDeclE) Signature
    , lfd2sghdM :: Map (Loc FuncDeclE) (Signature, Handler VarId)
    , lvr2lvdOrlfdM :: Map (Loc VarRefE) (Either (Loc VarDeclE) [Loc FuncDeclE])
    , lvr2vidOrsghdM :: Map (Loc VarRefE)
                       (Either VarId [(Signature, Handler VarId)])
    , pidsM     :: Map ProcId ()
    , lchr2lchdM :: Map (Loc ChanRefE) (Loc ChanDeclE)
    , lchd2chidM :: Map (Loc ChanDeclE) ChanId
    }

-- | Context used in type inference
type TypeInferenceEnv = Map Text SortId
                      :& Map (Loc VarDeclE) SortId
                      :& Map (Loc FuncDeclE) Signature
                      :& Map (Loc VarRefE) (Loc VarDeclE :| [Loc FuncDeclE])
                      :& Map (Loc ChanRefE) (Loc ChanDeclE)
                      :& Map (Loc ChanDeclE) ChanId
                      :& Map ProcId ()

-- | Compile a subset of TorXakis, using the given external definitions.
subCompile :: ( DefinesAMap (Loc ChanRefE) (Loc ChanDeclE) e (Map Text (Loc ChanDeclE))
              , HasVarReferences e
              , DeclaresVariables e
              , HasTypedVars TypeInferenceEnv e
              , Data e )
           => Sigs VarId
           -> [ChanId]
           -> [VarId]
           -> Int
           -> String
           -> TxsParser e
           -> (SubCompileMaps -> e -> CompilerM a)
           -> CompilerM (Id, a)
subCompile sigs chids vids unid str expP cmpF = do
    edecl <- liftEither $ parse 0 "" str expP
    setUnid unid

    let
        lchd2chid :: Map (Loc ChanDeclE) ChanId
        lchd2chid = Map.fromList $ zip (chIdToLoc <$> chids) chids

        text2chid :: Map Text (Loc ChanDeclE)
        text2chid = Map.fromList $ zip (ChanId.name <$> chids) (chIdToLoc <$> chids)

        pids :: Map ProcId ()
        pids = Map.fromList $ zip (pro sigs) (repeat ())

    lchr2lchd <- getMap text2chid edecl  :: CompilerM (Map (Loc ChanRefE) (Loc ChanDeclE))

    let
        lvd2vid :: [(Loc VarDeclE, VarId)]
        lvd2vid = zip (varIdToLoc <$> vids) vids

        text2lvd :: Map Text (Loc VarDeclE)
        text2lvd = Map.fromList $
                     zip (VarId.name . snd <$> lvd2vid) (fst <$> lvd2vid)

        text2sghd :: [(Text, (Signature, Handler VarId))]
        text2sghd = do
            (t, shmap) <- Map.toList . toMap . func $ sigs
            (s, h) <- Map.toList shmap
            return (t, (s, h))

    lfd2sghd <- forM text2sghd $ \(t, (s, h)) -> do
        i <- getNextId
        return (PredefLoc t i, (s, h))

    let
        text2lfd :: Map Text [Loc FuncDeclE]
        text2lfd = Map.fromListWith (++) $
            zip (fst <$> text2sghd) (pure . fst <$> lfd2sghd)
        text2sid :: Map Text SortId
        text2sid = sort sigs
        lvd2sid :: Map (Loc VarDeclE) SortId
        lvd2sid = Map.fromList . fmap (second varsort) $ lvd2vid
        lfd2sg :: Map (Loc FuncDeclE) Signature
        lfd2sg = Map.fromList $ fmap (second fst) lfd2sghd

    lvr2lvdOrlfd <- Map.fromList <$> mapRefToDecls (text2lvd :& text2lfd) edecl

    let mm =  text2sid :& lvd2sid :& lfd2sg :& lvr2lvdOrlfd
           :& lchr2lchd :& lchd2chid :& pids
    lvd2sid' <- Map.fromList <$> inferVarTypes mm edecl
    lvd2vid  <- Map.fromList <$> mkVarIds (lvd2sid' <.+> lvd2sid) edecl

    let mm' =  lvr2lvdOrlfd
            :& lvd2vid
            :& Map.fromList lfd2sghd

    lvr2vidOrsghd <- liftEither $ varDefsFromExp mm' edecl

    let cmpMaps = SubCompileMaps
            { text2sidM = text2sid
            , lvd2sidM = lvd2sid' <.+> lvd2sid
            , lvd2vidM = lvd2vid
            , text2lfdM = text2lfd
            , lfd2sgM = lfd2sg
            , lfd2sghdM = Map.fromList lfd2sghd
            , lvr2lvdOrlfdM = lvr2lvdOrlfd
            , lvr2vidOrsghdM = lvr2vidOrsghd
            , pidsM = pids
            , lchr2lchdM = lchr2lchd
            , lchd2chidM = lchd2chid
            }

    exp <- cmpF cmpMaps edecl

    unid' <- getUnid
    return (Id unid', exp)

