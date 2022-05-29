{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Pact.Core.IR.TCRemy where

import Control.Lens hiding (Level)
import Control.Monad.Reader
import Control.Monad.ST
import Data.Foldable(traverse_)
import Data.List.NonEmpty(NonEmpty(..))
import Data.STRef
import Data.Text(Text)

import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import qualified Data.RAList as RAList

import Pact.Core.Builtin
import Pact.Core.Type
import Pact.Core.Names
import qualified Pact.Core.IR.Term as IR
import qualified Pact.Core.Typed.Term as Typed

-- inference based on https://okmij.org/ftp/ML/generalization.html
-- Note: Type inference levels in the types
-- a-la sound-lazy might be worth implementing later on.
-- The eager implementation is simpler to maintain and extend to typeclasses.

type UniqueSupply s = STRef s Unique
type Level = Int
type TCType s = Type (TvRef s)
type IRTerm b i = IR.Term Name TypeVar b i
type TypedTCTerm s b i = Typed.Term Name (TvRef s) b i
type TypedTerm b i = Typed.Term Name NamedDeBruijn b i

-- note, we will debruijnize, so this is purely for
-- Display purposes
data TypeScheme tv =
  TypeScheme [tv] (Type tv)

data Tv s
  = Unbound !Text !Unique !Level
  | Bound !Text !Unique
  | Link !(Type (TvRef s))
  deriving Eq

-- Note: TyVar equality
-- is reference equality
newtype TvRef s =
  TvRef (STRef s (Tv s))
  deriving Eq


data TCState s b
  = TCState
  { _tcSupply :: UniqueSupply s
  -- ^ Supply for fresh variables.
  , _tcVarEnv :: RAList.RAList (TypeScheme (TvRef s))
  -- Variable environment for locally bound and top level names
  , _tcBuiltins :: b -> Type NamedDeBruijn
  -- ^ Builtins map, that uses the enum instance
  , _tcLevel :: STRef s Level
  -- Type Variable "Region"
  }

makeLenses ''TCState

type InferT s b a = ReaderT (TCState s b) (ST s) a

_dbgType :: TCType s -> InferT s b (Type String)
_dbgType = \case
  TyVar tv -> readTvRef tv >>= \case
    Unbound u l _ -> pure (TyVar ("unbound" <> show (u, l)))
    Bound u l -> pure (TyVar ("bound" <> show (u, l)))
    Link ty -> _dbgType ty
  TyFun l r -> TyFun <$> _dbgType l <*> _dbgType r
  TyRow r -> TyRow <$> _dbgRow r
  TyTable r -> TyTable <$> _dbgRow r
  TyList t -> TyList <$> _dbgType t
  TyPrim p -> pure (TyPrim p)
  TyCap -> pure TyCap
  TyForall {} -> fail "impredicative"
  where
  _dbgRow = undefined

enterLevel :: InferT s b ()
enterLevel = do
  lref <- asks _tcLevel
  lift (modifySTRef' lref succ)

leaveLevel :: InferT s b ()
leaveLevel = do
  lref <- asks _tcLevel
  lift (modifySTRef' lref pred)

currentLevel :: InferT s b Level
currentLevel =
  asks _tcLevel >>= lift . readSTRef

readTvRef :: TvRef s -> InferT s b (Tv s)
readTvRef (TvRef tv) = lift (readSTRef tv)

writeTvRef :: TvRef s -> Tv s -> InferT s b ()
writeTvRef (TvRef tv) t = lift (writeSTRef tv t)

newTvRef :: InferT s b (TvRef s)
newTvRef = do
  uref <- asks _tcSupply
  u <- lift (readSTRef uref)
  let tvName = "'a_" <> T.pack (show (_unique u))
  l <- currentLevel
  lift (modifySTRef' uref (+ 1))
  TvRef <$> lift (newSTRef (Unbound tvName u l))

---------------------------------------------------------------
-- Instantiations
---------------------------------------------------------------

-- Todo: unsafe map access
-- instantiate :: TypeScheme (TvRef s) -> InferT s b (TCType s)
-- instantiate (TypeScheme ts ty) = do
--   nts <- fmap TyVar <$> traverse (const newTvRef) ts
--   let m = IntMap.fromList $ zip (_unique . snd <$> ts) nts
--   instBound m ty
--   where
--   instBound m = \case
--     t@(TyVar tv) -> readTvRef tv >>= \case
--       Bound _ (Unique u) -> pure (m IntMap.! u)
--       Link lt -> instBound m lt
--       _ -> pure t
--     TyPrim p -> pure (TyPrim p)
--     TyFun l r ->
--       TyFun <$> instBound m l <*> instBound m r
--     TyRow r -> TyRow <$> instBoundRow m r
--     TyList t -> TyList <$> instBound m t
--     TyTable r -> TyTable <$> instBoundRow m r
--     t -> pure t
--   instBoundRow _m EmptyRow = pure EmptyRow
--   instBoundRow m t@(RowVar rv) = readTvRef rv >>= \case
--     Bound _ (Unique b) -> case (m IntMap.! b) of
--       TyVar rv' -> pure (RowVar rv')
--       _ -> pure t
--     Link lt -> instBound m lt >>= \case
--       TyRow r' -> pure r'
--       TyVar rv' -> pure (RowVar rv')
--       _ -> fail "impossible?"
--     _ -> pure t
--   instBoundRow m t@(RowTy o mrv) = do
--     obj <- traverse (instBound m) o
--     case mrv of
--       Just rv -> readTvRef rv >>= \case
--         Bound _ (Unique b) -> case (m IntMap.! b) of
--           TyVar rv' -> pure (RowTy obj (Just rv'))
--           _ -> pure t
--         Link lt -> instBound m lt >>= \case
--           TyRow (RowTy obj' r) -> pure (RowTy (Map.union obj obj') r)
--           TyRow EmptyRow -> pure (RowTy obj Nothing)
--           TyRow (RowVar rv') -> pure (RowTy obj (Just rv'))
--           TyVar rv' -> pure (RowTy obj (Just rv'))
--           _ -> fail "impossible?"
--         _ -> pure t
--       Nothing -> pure (RowTy obj Nothing)

instantiateWithTerm
  :: TypeScheme (TvRef s)
  -> TypedTCTerm s b i
  -> InferT s b (TCType s, TypedTCTerm s b i)
instantiateWithTerm (TypeScheme ts ty) term = do
  nts <- fmap TyVar <$> traverse (const newTvRef) ts
  let m = zip ts nts
  ty' <- instBound m ty
  case nts of
    x:xs -> pure (ty', Typed.TyApp term (x:|xs) (term ^. Typed.termInfo))
    [] -> pure (ty', term)
  where
  instBound m = \case
    t@(TyVar tv) -> readTvRef tv >>= \case
      Bound{} -> case lookup tv m of
        Just t' -> pure t'
        Nothing -> pure t
      Link lt -> instBound m lt
      _ -> pure t
    TyPrim p -> pure (TyPrim p)
    TyFun l r ->
      TyFun <$> instBound m l <*> instBound m r
    TyRow r -> TyRow <$> instBoundRow m r
    TyList t -> TyList <$> instBound m t
    TyTable r -> TyTable <$> instBoundRow m r
    t -> pure t
  instBoundRow _m EmptyRow = pure EmptyRow
  instBoundRow m t@(RowVar rv) = readTvRef rv >>= \case
    Bound{} -> case lookup rv m of
      Just (TyVar rv') -> pure (RowVar rv')
      _ -> pure t
    Link lt -> instBound m lt >>= \case
      TyRow r' -> pure r'
      TyVar rv' -> pure (RowVar rv')
      _ -> fail "impossible?"
    _ -> pure t
  instBoundRow m t@(RowTy o mrv) = do
    obj <- traverse (instBound m) o
    case mrv of
      Just rv -> readTvRef rv >>= \case
        Bound{} -> case lookup rv m of
          Just (TyVar rv') -> pure (RowTy obj (Just rv'))
          _ -> pure t
        Link lt -> instBound m lt >>= \case
          TyRow (RowTy obj' r) -> pure (RowTy (Map.union obj obj') r)
          TyRow EmptyRow -> pure (RowTy obj Nothing)
          TyRow (RowVar rv') -> pure (RowTy obj (Just rv'))
          TyVar rv' -> pure (RowTy obj (Just rv'))
          _ -> fail "impossible?"
        _ -> pure t
      Nothing -> pure (RowTy obj Nothing)

instantiateImported :: Type NamedDeBruijn -> InferT s b (TCType s, [TvRef s])
instantiateImported = \case
  TyForall tvs ty -> do
    ntvs <- traverse (const newTvRef) tvs
    let rl = RAList.fromList (reverse (NE.toList ntvs))
    (, NE.toList ntvs) <$> inst rl ty
  ty -> (, []) <$> inst mempty ty
  where
  inst rl = \case
    TyVar (NamedDeBruijn (DeBruijn i) _) -> pure (TyVar (rl RAList.!! i))
    TyPrim p -> pure (TyPrim p)
    TyFun l r -> TyFun <$> inst rl l <*> inst rl r
    TyRow r -> TyRow <$> instRow rl r
    TyList t -> TyList <$> inst rl t
    TyTable t -> TyTable <$> instRow rl t
    TyCap -> pure TyCap
    -- Impredicative type might work
    -- If we change unification.
    TyForall _ _ -> fail "unsupported impredicative polymorphism"
  instRow rl (RowVar (NamedDeBruijn (DeBruijn i) _)) = pure (RowVar (rl RAList.!! i))
  instRow _rl EmptyRow = pure EmptyRow
  instRow rl (RowTy obj mrv) = do
    obj' <- traverse (inst rl) obj
    case mrv of
      Just (NamedDeBruijn (DeBruijn i) _) -> pure (RowTy obj' (Just (rl RAList.!! i)))
      Nothing -> pure (RowTy obj' Nothing)

-- todo: factor copy pasted sections
occurs :: TvRef s -> TCType s -> InferT s b ()
occurs tv = \case
  TyVar tv' | tv == tv' -> fail "occurs check failed"
  TyVar tv' -> bindRef tv'
  TyFun l r -> occurs tv l *> occurs tv r
  TyRow r -> occursRow r
  TyList l -> occurs tv l
  TyTable r -> occursRow r
  _ -> pure ()
  where
  bindRef tv' = readTvRef tv' >>= \case
    Unbound n u l' -> do
      ml <- minLevel
      writeTvRef tv' (Unbound n u ml)
      where
      minLevel = readTvRef tv >>= \case
        Unbound _ _ l -> pure (min l l')
        _ -> pure l'
    Link ty -> occurs tv ty
    _ -> pure ()
  occursRow (RowVar tv') = do
    when (tv == tv') $ fail "occurs check failed for row variable"
    bindRef tv'
  occursRow EmptyRow = pure ()
  occursRow (RowTy obj mtv) = do
    when (Just tv == mtv) $ fail "occurs check failed for row variable"
    traverse_ (occurs tv) obj
    case mtv of
      Just tv' -> bindRef tv'
      Nothing -> pure ()

unifyTyVar :: TvRef s -> TCType s -> InferT s b ()
unifyTyVar tv t1 = readTvRef tv >>= \case
  Unbound{} -> do
    occurs tv t1
    writeTvRef tv (Link t1)
  Link t2 -> unify t2 t1
  _ -> pure ()

unify :: TCType s -> TCType s -> InferT s b ()
unify t1 t2 | t1 == t2 = pure ()
unify (TyVar tv) t = unifyTyVar tv t
unify t (TyVar tv) = unifyTyVar tv t
unify (TyFun l r) (TyFun l' r') = unify l l' *> unify r r'
unify (TyRow r) (TyRow r') = unifyRow r r'
unify (TyList t) (TyList t') = unify t t'
unify (TyTable r) (TyTable r') = unifyRow r r'
unify (TyPrim p) (TyPrim p') | p == p' = pure ()
unify TyCap TyCap = pure ()
unify _ _ = fail "types do not unify"

unifyRow :: Row (TvRef s) -> Row (TvRef s) -> InferT s b ()
unifyRow (RowVar n) t = unifyTyVar n (TyRow t)
unifyRow t (RowVar n) = unifyTyVar n (TyRow t)
unifyRow EmptyRow EmptyRow = pure ()
unifyRow (RowTy _ (Just rv)) EmptyRow = unifyTyVar rv (TyRow EmptyRow)
unifyRow EmptyRow (RowTy _ (Just rv)) = unifyTyVar rv (TyRow EmptyRow)
unifyRow (RowTy objL lrv) (RowTy objR rrv') =
  case (lrv, rrv') of
    -- Two open rows, we unify them back into open rows
    -- with each other's fields that are missing
    (Just tvl, Just tvr) -> do
      traverse_ (uncurry unify) (Map.intersectionWith (,) objL objR)
      leftRv <- newTvRef
      rightRv <- newTvRef
      let notInR = Map.difference objL objR
          notInL = Map.difference objR objL
      unifyTyVar tvl (TyRow (RowTy notInL (Just leftRv)))
      unifyTyVar tvr (TyRow (RowTy notInR (Just rightRv)))
    -- note: the NOTHING branch here means a closed row,
    -- therefore the open row's fields must be a subset.
    (Just tv, Nothing) -> unifyWithClosed tv objL objR
    (Nothing, Just tv) -> unifyWithClosed tv objR objL
    (Nothing, Nothing) -> do
      when (Map.keys objL /= Map.keys objR) $ fail "closed rows do not unify"
      traverse_ (uncurry unify) (Map.intersectionWith (,) objL objR)
    where
    unifyWithClosed tv m m' = do
      when (not $ Map.isSubmapOfBy (\_ _ -> True) m m') $ fail "Closed rows submap check"
      traverse_ (uncurry unify) (Map.intersectionWith (,) m m')
      -- members not in submap
      let diff = Map.difference m' m
      unifyTyVar tv (TyRow (RowTy diff Nothing))
unifyRow _ _ = fail "row unification failed"

generalizeWithTerm
  :: TCType s
  -> TypedTCTerm s b i
  -> InferT s b (TypeScheme (TvRef s), TypedTCTerm s b i)
generalizeWithTerm ty term = do
  sts <- lift (newSTRef Set.empty)
  (ftvs, ty') <- gen' sts ty
  case ftvs of
    [] -> pure (TypeScheme [] ty', term)
    (x:xs) -> pure (TypeScheme ftvs ty', Typed.TyAbs (x:|xs) term (term ^. Typed.termInfo))
  where
  gen' sts (TyVar tv) = readTvRef tv >>= \case
    Unbound n u l -> do
      cl <- currentLevel
      if l > cl then do
        s <- lift (readSTRef sts)
        writeTvRef tv (Bound n u)
        if Set.member u s then pure ([], TyVar tv)
        else lift (writeSTRef sts (Set.insert u s)) *> pure ([tv], TyVar tv)
      else pure ([], TyVar tv)
    Link t' -> gen' sts t'
    Bound _ _ -> pure ([], TyVar tv)
  gen' sts (TyFun l r) = do
    (ftvl, l') <- gen' sts l
    (ftvr, r') <- gen' sts r
    pure (ftvl ++ ftvr,TyFun l' r')
  gen' _ t@TyPrim{} = pure ([], t)
  gen' sts (TyRow r) = over _2 TyRow <$> genRow sts r
  gen' sts (TyList t) = over _2 TyList <$> gen' sts t
  gen' sts (TyTable t) = over _2 TyTable <$> genRow sts t
  gen' _sts TyCap = pure ([], TyCap)
  gen' _sts t@TyForall{} = pure ([], t)
  genRow _sts EmptyRow = pure ([], EmptyRow)
  genRow sts (RowVar rv) = readTvRef rv >>= \case
    Unbound n u l -> do
      cl <- currentLevel
      if l > cl then do
        s <- lift (readSTRef sts)
        writeTvRef rv (Bound n u)
        if Set.member u s then pure ([], RowVar rv)
        else lift (writeSTRef sts (Set.insert u s)) *> pure ([rv], RowVar rv)
      else pure ([], RowVar rv)
    Link t' -> gen' sts t' >>= \case
      (l, TyRow r) -> pure (l, r)
      _ -> fail "found row variable instantiate to top level type"
    Bound _ _ -> pure ([], RowVar rv)
  genRow sts (RowTy obj mrv) = do
    objTup <- traverse (gen' sts) obj
    let obj' = snd <$> objTup
        ftvs = concat $ fmap fst $ Map.elems objTup
    case mrv of
      Just tv -> readTvRef tv >>= \case
        Unbound n u l -> do
          cl <- currentLevel
          if l > cl then do
            s <- lift (readSTRef sts)
            writeTvRef tv (Bound n u)
            if Set.member u s then pure (ftvs, RowTy obj' mrv)
            else lift (writeSTRef sts (Set.insert u s)) *> pure (ftvs ++ [tv], RowTy obj' mrv)
          else pure ([], RowTy obj' mrv)
        Link t' -> gen' sts t' >>= \case
          (l, TyRow (RowVar v')) -> pure (ftvs ++ l, RowTy obj' (Just v'))
          (l, TyRow EmptyRow) -> pure (ftvs ++ l, RowTy obj' Nothing)
          (l, TyRow (RowTy objr rvr)) -> pure (ftvs ++ l, RowTy (Map.union obj' objr) rvr)
          _ -> fail "Row variable linked to non-row"
        Bound _ _ -> pure (ftvs, RowTy obj' mrv)
      Nothing -> pure (ftvs, RowTy obj' Nothing)

liftTypeVar :: Type TypeVar -> InferT s b (TCType s)
liftTypeVar = \case
  TyVar tyv -> TyVar <$> liftRef tyv
  TyPrim p -> pure (TyPrim p)
  TyFun l r ->
    TyFun <$> liftTypeVar l <*> liftTypeVar r
  TyRow r -> TyRow <$> liftTVRow r
  TyTable r -> TyTable <$> liftTVRow r
  TyList l -> TyList <$> liftTypeVar l
  TyCap -> pure TyCap
  TyForall _ _ -> fail "impossible"
  where
  -- BIG TODO: placeholder impl, DEFINITELY
  -- unsound in the presence of type anns (vars that should not be generalized)
  -- would get a level higher than where they were declared.
  -- Type anns need to be indexed @ their declared binder
  liftRef tyv = do
    level <- currentLevel
    let name = _tyVarName tyv
        u = _tyVarUnique tyv
    TvRef <$> lift (newSTRef (Unbound name u level))
  liftTVRow = \case
    EmptyRow -> pure EmptyRow
    RowVar v -> RowVar <$> liftRef v
    RowTy obj mrv -> do
      obj' <- traverse liftTypeVar obj
      mrv' <- traverse liftRef mrv
      pure (RowTy obj' mrv')

-- Todo: bidirectionality
inferTerm :: IRTerm b i -> InferT s b (TCType s, TypedTCTerm s b i)
inferTerm = \case
  IR.Var n@(Name _ (LocallyBoundName di)) i -> do
    views tcVarEnv (`RAList.lookup` (_debruijn di)) >>= \case
      Just ts -> do
        let v' = Typed.Var n i
        instantiateWithTerm ts v'
      Nothing -> fail ("unbound variable in term infer" <> show n)
  IR.Var _ _ -> fail "unsupported top level"
  IR.Lam n nts e i -> do
    let names = fst <$> nts
    ntys <- fmap TyVar <$> traverse (const newTvRef) names
    -- Todo: bidirectionality
    -- nts' <- (mapped._1.traversed) liftTypeVar nts
    let m = RAList.fromList (NE.toList (NE.reverse (TypeScheme [] <$> ntys)))
    (ty, e') <- locally tcVarEnv (m RAList.++) $ inferTerm e
    let nts' = NE.zip names ntys
        rty = foldr TyFun ty ntys
    pure (rty, Typed.Lam n nts' e' i)
  IR.App e (arg :| args) i -> do
    tv1 <- TyVar <$> newTvRef
    (te, e') <- inferTerm e
    (targ, arg') <- inferTerm arg
    unify te (TyFun targ tv1)
    (ret, args') <- inferArgs tv1 args
    pure (ret, Typed.App e' (arg' :| args') i)
    where
    inferArgs tfun (x:xs) = do
      tout <- TyVar <$> newTvRef
      (tx, x') <- inferTerm x
      unify tfun (TyFun tx tout)
      (outf, xs') <- inferArgs tout xs
      pure (outf, x':xs')
    inferArgs tout [] = pure (tout, [])
  -- Todo: bidirectionaliry
  IR.Let n _ e1 e2 i -> do
    enterLevel
    (te1, e1Unqual) <- inferTerm e1
    leaveLevel
    (ts, e1Qual) <- generalizeWithTerm te1 e1Unqual
    (te2, e2') <- locally tcVarEnv (RAList.cons ts) $ inferTerm e2
    pure (te2, Typed.Let n e1Qual e2' i)
  IR.Block nel i -> do
    nelTup <- traverse inferTerm nel
    let nel' = snd <$> nelTup
        outTy = fst (NE.last nelTup)
    pure (outTy, Typed.Block nel' i)
  IR.Error e i -> do
    tv <- TyVar <$> newTvRef
    pure (tv, Typed.Error e tv i)
  -- Todo: Here, convert to dictionary
  IR.Builtin b i -> do
    tyImported <- views tcBuiltins ($ b)
    (ty, tvs) <- instantiateImported tyImported
    let tvs' = TyVar <$> tvs
    let term' = Typed.Builtin b i
    case tvs' of
      x:xs -> pure (ty, Typed.TyApp term' (x:|xs) i)
      [] -> pure (ty, term')
  -- TODO: note,
  -- for this to work, we have to have proper bidirectionality working, including scoped type variables working fine
  IR.DynAccess {} -> error "todo: Dyn access"
  IR.Constant l i -> pure (typeOfLit l, Typed.Constant l i)
  -- note: object literals are closed rows.
  IR.ObjectLit obj i -> do
    objTup <- traverse inferTerm obj
    let obj' = snd <$> objTup
        objTy = TyRow (RowTy (fst <$> objTup) Nothing)
    pure (objTy, Typed.ObjectLit obj' i)
  IR.ListLit li i -> do
    tv <- TyVar <$> newTvRef
    liTup <- traverse inferTerm li
    _ <- traverse (unify tv . view _1) liTup
    pure (TyList tv, Typed.ListLit tv (snd <$> liTup) i)


-- | Transform types into their debruijn-indexed version
-- Essentially: Start at depth 0:
--  rename : (Term, Γ, Int) -> IxTerm
--  rename (ΛX.e, tyEnv, DEPTH) = Λ. (rename (e, tyEnv[depth/X], DEPTH+1))
--  .. other cases are simply renaming recursively and calling `renameType`
--  on occurences of Type
--
--  NOTE: the passed in DEPTH is 1 higher than the highest binder.
--
--  renameType : (Type, Γ, Int) -> IxType
--  renameType (a, env, DEPTH) = DEPTH - env(a) - 1
--  .. other recursive cases are straightforward
--
--  Quip: when we debruijnize types, we expect no impredicative polymorphism atm,
--  thus we will fail on universially quantified types found in application and
--  var binding sites.
--  The typechecker does not spit out impredicative polymorphism, but while
--  it would be trivial to support their renaming here, I'd rather fail
--  for now as the typechecker does not support it and it functions as a sanity check
debruijnizeTermTypes :: TypedTCTerm s b i -> InferT s b (TypedTerm b i)
debruijnizeTermTypes = dbj [] 0
  where
  dbj :: [(TvRef s, NamedDeBruijn)] -> DeBruijn -> TypedTCTerm s b i -> InferT s b (TypedTerm b i)
  dbj env depth = \case
    Typed.Var n i -> pure (Typed.Var n i)
    Typed.Lam n nts e i -> do
      nts' <- (traversed._2) (dbjTyp env depth) nts
      e' <- dbj env depth e
      pure (Typed.Lam n nts' e' i)
    Typed.App l r i ->
      Typed.App <$> dbj env depth l <*> traverse (dbj env depth) r <*> pure i
    Typed.Let n e1 e2 i ->
      Typed.Let n <$> dbj env depth e1 <*> dbj env depth e2 <*> pure i
    Typed.TyApp e args i -> do
      e' <- dbj env depth e
      args' <- traverse (dbjTyp env depth) args
      pure (Typed.TyApp e' args' i)
    Typed.TyAbs ntys e i -> do
      let len = fromIntegral (NE.length ntys)
          ixs = NE.fromList [depth .. depth + len - 1]
      names <- traverse (nameTvs (depth + len)) (NE.zip ntys ixs)
      let env' = NE.toList $ NE.zip ntys names
      Typed.TyAbs names <$> dbj (env' ++ env) (depth + len) e <*> pure i
    Typed.Block nel i ->
      Typed.Block <$> traverse (dbj env depth) nel <*> pure i
    Typed.ObjectLit obj i ->
      Typed.ObjectLit <$> traverse (dbj env depth) obj <*> pure i
    Typed.ListLit ty v i ->
      Typed.ListLit <$> dbjTyp env depth ty <*> traverse (dbj env depth) v <*> pure i
    Typed.Error e t i ->
      Typed.Error e <$> dbjTyp env depth t <*> pure i
    Typed.Builtin b i -> pure (Typed.Builtin b i)
    Typed.Constant l i -> pure (Typed.Constant l i)

nameTvs :: DeBruijn -> (TvRef s, DeBruijn) -> InferT s b NamedDeBruijn
nameTvs depth (nt, i) = readTvRef nt >>= \case
  Bound n _ -> pure (NamedDeBruijn (depth - i - 1) n)
  _ -> fail "found unbound variable"

debruijnizeTypeScheme :: TypeScheme (TvRef s) -> InferT s b (Type NamedDeBruijn)
debruijnizeTypeScheme (TypeScheme tvs t) = case tvs of
  x:xs -> do
    let len = fromIntegral (length tvs)
    let ixs = NE.fromList [0.. len - 1]
    names <- traverse (nameTvs len) (NE.zip (x:|xs) ixs)
    TyForall names <$> dbjTyp (zip tvs (NE.toList names)) len t
  [] -> dbjTyp [] 0 t

dbjTyp
  :: [(TvRef s, NamedDeBruijn)]
  -> DeBruijn
  -> TCType s
  -> InferT s b (Type NamedDeBruijn)
dbjTyp env depth = \case
  TyVar n -> case lookup n env of
    Just v -> pure (TyVar v)
    Nothing -> readTvRef n >>= \case
      Unbound {} -> fail "unbound type"
      Bound{} -> fail "impossible"
      Link ty -> dbjTyp env depth ty
  TyPrim p -> pure (TyPrim p)
  TyFun l r -> TyFun <$> dbjTyp env depth l <*> dbjTyp env depth r
  TyRow r -> TyRow <$> dbjRow env depth r
  TyList l -> TyList <$> dbjTyp env depth l
  TyTable r -> TyTable <$> dbjRow env depth r
  TyCap -> pure TyCap
  _ -> fail "impredicative"

dbjRow
  :: [(TvRef s, NamedDeBruijn)]
  -> DeBruijn
  -> Row (TvRef s)
  -> InferT s b (Row NamedDeBruijn)
dbjRow env depth = \case
  RowVar rv -> case lookup rv env of
    Just v -> pure (RowVar v)
    Nothing -> fail "unbound row var"
  EmptyRow -> pure EmptyRow
  RowTy obj mrv -> do
    obj' <- traverse (dbjTyp env depth) obj
    case mrv of
      Just rv -> case lookup rv env of
        Just v -> pure (RowTy obj' (Just v))
        Nothing -> fail "unbound row var"
      Nothing -> pure (RowTy obj' Nothing)

tsToTyForall :: TypeScheme t -> Type t
tsToTyForall (TypeScheme ts t) = case ts of
  [] -> t
  (x:xs) -> TyForall (x:|xs) t

runInferTerm :: Supply -> (b -> Type NamedDeBruijn) -> IRTerm b i -> (Type NamedDeBruijn, TypedTerm b i)
runInferTerm u bfn term0 = runST $ do
  uref <- newSTRef u
  lref <- newSTRef 1
  let tcs = TCState uref mempty bfn lref
  flip runReaderT tcs $ do
    enterLevel
    (ty, term1) <- inferTerm term0
    leaveLevel
    (tys, term2) <- generalizeWithTerm ty term1
    ts <- debruijnizeTypeScheme tys
    term3 <- debruijnizeTermTypes term2
    pure (ts, term3)

-----------------------------------------
--- Built-in type wiring
------------------------------------------
-- todo: overloading

-- todo: debruijnize automatically
rawBuiltinType :: RawBuiltin -> Type NamedDeBruijn
rawBuiltinType = \case
  RawAdd -> binaryInt
  RawSub -> binaryInt
  RawMultiply -> binaryInt
  RawDivide -> binaryInt
  RawNegate -> unaryInt
  RawAnd -> binaryBool
  RawOr -> binaryBool
  RawNot -> TyBool :~> TyBool
  RawEq -> binaryIntComp
  RawNeq -> binaryIntComp
  RawGT -> binaryIntComp
  RawGEQ -> binaryIntComp
  RawLT -> binaryIntComp
  RawLEQ -> binaryIntComp
  RawBitwiseAnd -> binaryInt
  RawBitwiseOr -> binaryInt
  RawBitwiseXor -> binaryInt
  RawBitwiseFlip -> TyInt :~> TyInt
  RawBitShift -> unaryInt
  RawAbs -> unaryInt
  RawRound -> roundingFn
  RawCeiling -> roundingFn
  RawExp -> unaryDecimal
  RawFloor -> roundingFn
  RawLn -> unaryDecimal
  RawLogBase -> binaryDecimal
  RawMod -> binaryInt
  RawMap ->
    let aVar = nd "a" 1
        bVar = nd "b" 0
        a = TyVar aVar
        b = TyVar bVar
    in TyForall (aVar :| [bVar]) ((a :~> b) :~> TyList a :~> TyList b)
  RawFold ->
    let aVar = nd "a" 1
        bVar = nd "b" 0
        a = TyVar aVar
        b = TyVar bVar
    in TyForall (aVar :| [bVar]) ((a :~> b :~> a) :~> a :~> TyList b :~> a)
  RawFilter ->
    let aVar = nd "a" 0
        a = TyVar aVar
    in TyForall (aVar :| []) ((a :~> TyBool) :~> TyList a :~> TyList a)
  RawIf ->
    let aVar = nd "a" 0
        a = TyVar aVar
    in TyForall (aVar :| []) (TyBool :~> (TyUnit :~> a) :~> (TyUnit :~> a) :~> a)
  RawIntToStr ->
    TyInt :~> TyString
  RawConcat ->
    TyList TyString :~> TyString
  RawStrToInt ->
    TyString :~> TyInt
  RawTake ->
    let aVar = nd "a" 0
        a = TyVar aVar
    in TyForall (aVar :| []) (TyInt :~> TyList a :~> TyList a)
  RawDrop ->
    let aVar = nd "a" 0
        a = TyVar aVar
    in TyForall (aVar :| []) (TyInt :~> TyList a :~> TyList a)
  RawLength ->
    let aVar = nd "a" 0
        a = TyVar aVar
    in TyForall (aVar :| []) (TyList a :~> TyInt)
  RawDistinct ->
    TyList TyInt :~> TyList TyInt
  RawEnforce ->
    TyBool :~> TyString :~> TyUnit
  RawEnforceOne -> error "todo"
  RawEnumerate ->
    TyInt :~> TyInt :~> TyList TyInt
  RawEnumerateStepN ->
    TyInt :~> TyInt :~> TyInt :~> TyList TyInt
  where
  nd b a = NamedDeBruijn a b
  unaryInt = TyInt :~> TyInt
  binaryInt = TyInt :~> TyInt :~> TyInt
  unaryDecimal = TyDecimal :~> TyDecimal
  binaryDecimal = TyDecimal :~> TyDecimal :~> TyDecimal
  roundingFn = TyDecimal :~> TyInt
  binaryIntComp = TyInt :~> TyInt :~> TyBool
  binaryBool = TyBool :~> TyBool :~> TyBool
