{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Oden.Infer (
  Constraint,
  TypeError(..),
  Subst(..),
  TypeBinding(..),
  TypingEnvironment,
  inferExpr,
  inferDefinition,
  inferPackage,
  constraintsExpr
) where

import           Control.Arrow           (left)
import           Control.Monad.Except
import           Control.Monad.Identity
import           Control.Monad.RWS       hiding ((<>))

import           Data.List               (nub)
import qualified Data.Map                as Map
import qualified Data.Set                as Set

import qualified Oden.Core               as Core
import           Oden.Core.Operator
import qualified Oden.Core.Untyped       as Untyped
import           Oden.Environment        as Environment hiding (map)
import           Oden.Identifier
import           Oden.Infer.Environment
import           Oden.Infer.Substitution
import           Oden.Infer.Subsumption
import           Oden.SourceInfo
import           Oden.Type.Basic
import           Oden.Type.Polymorphic
import           Oden.Type.Signature

-------------------------------------------------------------------------------
-- Classes
-------------------------------------------------------------------------------

-- | Inference monad
type Infer a = (RWST
                  TypingEnvironment -- Typing environment
                  [Constraint]              -- Generated constraints
                  InferState                -- Inference state
                  (Except                   -- Inference errors
                    TypeError)
                  a)                        -- Result

-- | Inference state
data InferState = InferState { count :: Int }

-- | Initial inference state
initInfer :: InferState
initInfer = InferState { count = 0 }

type Constraint = (SourceInfo, Type, Type)

type Unifier = (Subst, [Constraint])

-- | Constraint solver monad
type Solve a = ExceptT TypeError Identity a


instance FTV Constraint where
  ftv (_, t1, t2) = ftv t1 `Set.union` ftv t2

instance Substitutable Constraint where
  apply s (si, t1, t2) = (si, apply s t1, apply s t2)

instance FTV TypeBinding where
  ftv (Package _ _ e)      = ftv e
  ftv (Local _ _ d)        = ftv d
  ftv (TypeAlias _ _ ps t) = foldl Set.union (ftv t) (map ftv ps)

instance Substitutable TypeBinding where
  apply _ (Package si n e) = Package si n e
  apply s (Local si n d) = Local si n (apply s d)
  apply _ (TypeAlias si n ps t) = TypeAlias si n ps t

instance FTV TypingEnvironment where
  ftv (Environment env) = ftv $ Map.elems env

instance Substitutable TypingEnvironment where
  apply s (Environment env) = Environment $ Map.map (apply s) env

data TypeError
  = UnificationFail SourceInfo Type Type
  | InfiniteType SourceInfo TVar Type
  | PackageNotInScope SourceInfo Name
  | NotInScope SourceInfo Identifier
  | MemberNotInPackage SourceInfo Name Name
  | UnificationMismatch SourceInfo [Type] [Type]
  | ArgumentCountMismatch (Core.Expr Type) [Type] [Type]
  | TypeSignatureSubsumptionError Name SubsumptionError
  | InvalidPackageReference SourceInfo Name
  | ValueUsedAsType SourceInfo Name
  deriving (Show, Eq)

-------------------------------------------------------------------------------
-- Inference
-------------------------------------------------------------------------------

-- | Run the inference monad
runInfer :: Environment TypeBinding -> Infer a -> Either TypeError (a, [Constraint])
runInfer env m = runExcept $ evalRWST m env initInfer

-- | Solve for the toplevel type of an expression in a given environment
inferExpr :: Environment TypeBinding -> Untyped.Expr -> Either TypeError Core.CanonicalExpr
inferExpr env ex = do
  (te, cs) <- runInfer env (infer ex)
  subst <- runSolve cs
  return $ closeOver (apply subst te)

-- | Return the internal constraints used in solving for the type of an expression
constraintsExpr :: Environment TypeBinding -> Untyped.Expr -> Either TypeError ([Constraint], Subst, Core.Expr Type, Scheme)
constraintsExpr env ex = do
  (te, cs) <- runInfer env (infer ex)
  subst <- runSolve cs
  let (sc, te') = closeOver $ apply subst te
  return (cs, subst, te', sc)

-- | Canonicalize and return the polymorphic toplevel type.
closeOver :: Core.Expr Type -> Core.CanonicalExpr
closeOver = normalize . generalize empty

-- | Unify two types
uni :: SourceInfo -> Type -> Type -> Infer ()
uni si t1 t2 = tell [(si, t1, t2)]

-- | Extend type environment
inEnv :: (Name, TypeBinding) -> Infer a -> Infer a
inEnv (x, sc) = local (`extend` (x, sc))

lookupTypeIn :: TypingEnvironment -> SourceInfo -> Name -> Infer Type
lookupTypeIn _ si "any" = return (TAny si)
lookupTypeIn _ si "int" = return (TBasic si TInt)
lookupTypeIn _ si "bool" = return (TBasic si TBool)
lookupTypeIn _ si "string" = return (TBasic si TString)
lookupTypeIn env si name =
  case Environment.lookup name env of
      Nothing             -> throwError $ NotInScope si (Unqualified name)
      Just Package{}      -> throwError $ InvalidPackageReference si name
      Just (Local _ _ _)  -> throwError $ ValueUsedAsType si name
      Just (TypeAlias _ _ _ t) -> return t

-- | Lookup type in the environment
lookupType :: SourceInfo -> Identifier -> Infer Type
lookupType si (Qualified pkg name) = do
  env <- ask
  case Environment.lookup pkg env of
      Just (Package _ _ env') ->
        lookupValueIn env' si name `catchError` onError
        where
        onError :: TypeError -> Infer Type
        onError NotInScope{} = throwError $ MemberNotInPackage si pkg name
        onError e = throwError e
      _              -> throwError $ PackageNotInScope si pkg
lookupType si (Unqualified name) = do
  env <- ask
  lookupTypeIn env si name

lookupValueIn :: TypingEnvironment -> SourceInfo -> Name -> Infer Type
lookupValueIn env si name =
  case Environment.lookup name env of
      Nothing             -> throwError $ NotInScope si (Unqualified name)
      Just Package{}      -> throwError $ InvalidPackageReference si name
      Just (Local _ _ sc) -> instantiate sc

-- | Lookup type of a value in the environment
lookupValue :: SourceInfo -> Identifier -> Infer Type
lookupValue si (Qualified pkg name) = do
  env <- ask
  case Environment.lookup pkg env of
      Just (Package _ _ env') ->
        lookupValueIn env' si name `catchError` onError
        where
        onError :: TypeError -> Infer Type
        onError NotInScope{} = throwError $ MemberNotInPackage si pkg name
        onError e = throwError e
      _              -> throwError $ PackageNotInScope si pkg
lookupValue si (Unqualified name) = do
  env <- ask
  lookupValueIn env si name

letters :: [String]
letters = [1..] >>= flip replicateM ['a'..'z']

fresh :: SourceInfo -> Infer Type
fresh si = do
    s <- get
    put s{count = count s + 1}
    return $ TVar si (TV (letters !! count s))

instantiate :: Scheme -> Infer Type
instantiate (Forall _ as t) = do
    as' <- mapM (fresh . getSourceInfo) as
    let s = Subst $ Map.fromList $ zip (map getBindingVar as) as'
    return $ apply s t

generalize :: Environment TypeBinding -> Core.Expr Type -> (Scheme, Core.Expr Type)
generalize env t  = (Forall (getSourceInfo t) as (Core.typeOf t), t)
    where as = map (TVarBinding Missing) (Set.toList $ ftv t `Set.difference` ftv env)

infer :: Untyped.Expr -> Infer (Core.Expr Type)
infer expr = case expr of
  Untyped.Literal si Untyped.Unit ->
    return (Core.Literal si Core.Unit (TUnit si))
  Untyped.Literal si (Untyped.Int n) ->
    return (Core.Literal si (Core.Int n) (TBasic si TInt))
  Untyped.Literal si (Untyped.Bool b) ->
    return (Core.Literal si (Core.Bool b) (TBasic si TBool))
  Untyped.Literal si (Untyped.String s) ->
    return (Core.Literal si (Core.String s) (TBasic si TString))

  Untyped.Subscript si s i -> do
    st <- infer s
    it <- infer i
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (getSourceInfo s) tv)
    uni (getSourceInfo it) (Core.typeOf it) (TBasic si TInt)
    return (Core.Subscript si st it tv)

  Untyped.Subslice si s (Untyped.Range e1 e2) -> do
    st <- infer s
    e1t <- infer e1
    e2t <- infer e2
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (getSourceInfo s) tv)
    uni (getSourceInfo e1t) (Core.typeOf e1t) (TBasic si TInt)
    uni (getSourceInfo e2t) (Core.typeOf e2t) (TBasic si TInt)
    return (Core.Subslice si st (Core.Range e1t e2t) (TSlice si tv))

  Untyped.Subslice si s (Untyped.RangeTo e) -> do
    st <- infer s
    et <- infer e
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (getSourceInfo s) tv)
    uni (getSourceInfo et) (Core.typeOf et) (TBasic si TInt)
    return (Core.Subslice si st (Core.RangeTo et) (TSlice si tv))

  Untyped.Subslice si s (Untyped.RangeFrom e) -> do
    st <- infer s
    et <- infer e
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (getSourceInfo s) tv)
    uni (getSourceInfo et) (Core.typeOf et) (TBasic si TInt)
    return (Core.Subslice si st (Core.RangeFrom et) (TSlice si tv))

  Untyped.UnaryOp si o e -> do
    rt <- case o of
              Positive   -> return (TBasic si TInt)
              Negative -> return (TBasic si TInt)
              Not    -> return (TBasic si TBool)
    te <- infer e
    uni (getSourceInfo te) (Core.typeOf te) rt
    return (Core.UnaryOp si o te rt)

  Untyped.BinaryOp si o e1 e2 -> do
    (ot, rt) <- case o of
                    Add               -> return (TBasic si TInt, TBasic si TInt)
                    Subtract          -> return (TBasic si TInt, TBasic si TInt)
                    Multiply          -> return (TBasic si TInt, TBasic si TInt)
                    Divide            -> return (TBasic si TInt, TBasic si TInt)
                    Equals            -> do tv <- fresh si
                                            return (tv, TBasic si TBool)
                    Concat            -> return (TBasic si TString, TBasic si TString)
                    LessThan          -> return (TBasic si TInt, TBasic si TBool)
                    GreaterThan       -> return (TBasic si TInt, TBasic si TBool)
                    LessThanEqual     -> return (TBasic si TInt, TBasic si TBool)
                    GreaterThanEqual  -> return (TBasic si TInt, TBasic si TBool)
                    And               -> return (TBasic si TBool, TBasic si TBool)
                    Or                -> return (TBasic si TBool, TBasic si TBool)
    te1 <- infer e1
    te2 <- infer e2
    uni (getSourceInfo te1) (Core.typeOf te1) ot
    uni (getSourceInfo te2) (Core.typeOf te2) ot
    return (Core.BinaryOp si o te1 te2 rt)

  Untyped.Symbol si x -> do
    t <- lookupValue si x
    return $ Core.Symbol si x t

  Untyped.Fn si (Untyped.NameBinding bsi a) b -> do
    tv <- fresh bsi
    tb <- inEnv (a, Local bsi a (Forall bsi [] tv)) (infer b)
    return (Core.Fn si (Core.NameBinding bsi a) tb (TFn si tv (Core.typeOf tb)))

  Untyped.NoArgFn si f -> do
    tf <- infer f
    return (Core.NoArgFn si tf (TNoArgFn si (Core.typeOf tf)))

  Untyped.Application si f [] -> do
    tv <- fresh si
    tf <- infer f
    case Core.typeOf tf of
      t@TUncurriedFn{} -> do
        uni (getSourceInfo tf) t (TUncurriedFn (getSourceInfo tf) [] tv)
        return (Core.UncurriedFnApplication si tf [] tv)
      -- No-param application of variadic function is automatically transformed
      -- to application of empty slice.
      t@(TVariadicFn _ [] variadicArg _) -> do
        uni (getSourceInfo tf) t (TVariadicFn (getSourceInfo tf) [] variadicArg tv)
        return (Core.UncurriedFnApplication si tf [Core.Slice (getSourceInfo variadicArg) [] variadicArg] tv)
      TVariadicFn _ nonVariadicArgs _ _ ->
        throwError (ArgumentCountMismatch tf nonVariadicArgs [])
      t -> do
        uni (getSourceInfo tf) t (TNoArgFn (getSourceInfo tf) tv)
        return (Core.NoArgApplication si tf tv)

  Untyped.Application si f ps -> do
    tf <- infer f
    case Core.typeOf tf of
      t@TUncurriedFn{} -> do
        tv <- fresh (getSourceInfo t)
        tps <- mapM infer ps
        uni (getSourceInfo tf) t (TUncurriedFn si (map Core.typeOf tps) tv)
        return (Core.UncurriedFnApplication si tf tps tv)
      t@(TVariadicFn _ nonVariadicTypes variadicType _) -> do
        tv <- fresh (getSourceInfo t)
        nonVariadicParams <- mapM infer (take (length nonVariadicTypes) ps)
        variadicParams <- mapM infer (drop (length nonVariadicTypes) ps)
        let sliceSi = if null variadicParams then Missing else getSourceInfo (head variadicParams)
        let allParams = nonVariadicParams ++ [Core.Slice sliceSi variadicParams variadicType]
        uni (getSourceInfo tf) t (TVariadicFn (getSourceInfo tf) (map Core.typeOf nonVariadicParams) variadicType tv)
        return (Core.UncurriedFnApplication si tf allParams tv)
      t ->
        foldM app tf ps
        where
        app :: Core.Expr Type -> Untyped.Expr -> Infer (Core.Expr Type)
        app tf' p = do
          tv <- fresh (getSourceInfo t)
          tp <- infer p
          uni (getSourceInfo tf) (Core.typeOf tf') (TFn (getSourceInfo tf) (Core.typeOf tp) tv)
          return (Core.Application si tf' tp tv)

  Untyped.Let si (Untyped.NameBinding bsi n) e b -> do
    te <- infer e
    tb <- inEnv (n, Local bsi n (Forall si [] (Core.typeOf te))) (infer b)
    return (Core.Let si (Core.NameBinding bsi n) te tb (Core.typeOf tb))

  Untyped.If si cond tr fl -> do
    tcond <- infer cond
    ttr <- infer tr
    tfl <- infer fl
    uni (getSourceInfo tcond) (Core.typeOf tcond) (TBasic si TBool)
    uni (getSourceInfo ttr) (Core.typeOf ttr) (Core.typeOf tfl)
    return (Core.If si tcond ttr tfl (Core.typeOf ttr))

  Untyped.Tuple si f s r -> do
    tf <- infer f
    ts <- infer s
    tr <- mapM infer r
    let t = TTuple si (Core.typeOf tf) (Core.typeOf ts) (map Core.typeOf tr)
    return (Core.Tuple si tf ts tr t)

  Untyped.Slice si es -> do
    tv <- fresh si
    tes <- mapM infer es
    mapM_ (uni si tv . Core.typeOf) tes
    return (Core.Slice si tes (TSlice si tv))

  Untyped.Block si es -> do
    tv <- fresh si
    tes <- mapM infer es
    case tes of
      [] -> uni si tv (TUnit si)
      _ -> uni si tv (Core.typeOf (last tes))
    return (Core.Block si tes tv)

resolveType :: SignatureExpr -> Infer Type
resolveType (TSUnit si) = return (TUnit si)
resolveType (TSVar si s) = return (TVar si (TV s))
resolveType (TSSymbol si i) = lookupType si i
resolveType (TSApp _si _e1 _e2) = error "Type constructor application not implemented yet."
resolveType (TSFn si de re) = TFn si <$> resolveType de <*> resolveType re
resolveType (TSNoArgFn si e) = TNoArgFn si <$> resolveType e
resolveType (TSTuple si fe se re) = TTuple si <$> resolveType fe
                                              <*> resolveType se
                                              <*> mapM resolveType re
resolveType (TSSlice si e) = TSlice si <$> resolveType e

resolveTypeSignature :: TypeSignature -> Infer Scheme
resolveTypeSignature (Explicit si bindings expr) = do
  t <- resolveType expr
  return (Forall si (map toVarBinding bindings) t)
  where
  toVarBinding (SignatureVarBinding si' s) = TVarBinding si' (TV s)
resolveTypeSignature (Implicit si expr) = do
  t <- resolveType expr
  return (Forall si (map (TVarBinding si) (Set.toList (ftv t))) t)

inferDef :: Untyped.Definition -> Infer Core.Definition
inferDef (Untyped.Definition si name s expr) = do
  tv <- fresh si
  env <- ask
  recType <- case s of
    Nothing -> return (Forall si [] tv)
    Just ts -> resolveTypeSignature ts
  te <- inEnv (name, Local si name recType) (infer expr)
  return (Core.Definition si name (generalize env te))

inferDefinition :: Environment TypeBinding -> Untyped.Definition -> Either TypeError Core.Definition
inferDefinition env def@(Untyped.Definition _ _ Nothing _) = do
  (Core.Definition si name (_, te), cs) <- runInfer env (inferDef def)
  subst <- runSolve cs
  return $ Core.Definition si name (closeOver (apply subst te))
inferDefinition env def@(Untyped.Definition _ _ (Just ts) _) = do
  (resolvedType, tsConstrains) <- runInfer env (resolveTypeSignature ts)
  (Core.Definition _ name ce, defConstraints) <- runInfer env (inferDef def)
  subst <- runSolve (tsConstrains ++ defConstraints)
  let (Forall si _ _, substExpr) = apply subst ce
  ce' <- left (TypeSignatureSubsumptionError name) $ subsume resolvedType substExpr
  return $ Core.Definition si name ce'

inferPackage :: Environment TypeBinding -> Untyped.Package -> Either TypeError (Core.Package, Environment TypeBinding)
inferPackage env (Untyped.Package (Untyped.PackageDeclaration psi name) imports defs) = do
  (env', inferred) <- foldM iter (env, []) defs
  return (Core.Package (Core.PackageDeclaration psi name) (map convertImport imports) inferred, env')
  where
  iter (e, inferred) d@Untyped.Definition{} = do
      td@(Core.Definition si n (sc, _)) <- inferDefinition e d
      return (extend e (n, Local si n sc), inferred ++ [td])
  convertImport (Untyped.Import si n) = Core.Import si n

normalize :: (Scheme, Core.Expr Type) -> (Scheme, Core.Expr Type)
normalize (Forall si _ body, te) = (Forall si tvarBindings (normtype body), te)
  where
    ord = zip (nub $ fv body) (map TV letters)

    fv :: Type -> [TVar]
    fv TAny{}                 = []
    fv TUnit{}                = []
    fv TBasic{}               = []
    fv (TTuple _ f s rs)      = fv f ++ fv s ++ concatMap fv rs
    fv (TVar _ a)             = [a]
    fv (TNoArgFn _ a)         = fv a
    fv (TFn _ a b)            = fv a ++ fv b
    fv (TUncurriedFn _ as r)  = concatMap fv as ++ fv r
    fv (TVariadicFn _ as v r) = concatMap fv as ++ fv v ++ fv r
    fv (TCon _ d r)           = fv d ++ fv r
    fv (TSlice _ t)           = fv t

    normtype t@TAny{}                = t
    normtype t@TUnit{}               = t
    normtype t@TBasic{}              = t
    normtype (TTuple si' f s r)       = TTuple si' (normtype f) (normtype s) (map normtype r)
    normtype (TNoArgFn si' a)         = TNoArgFn si' (normtype a)
    normtype (TFn si' a b)            = TFn si' (normtype a) (normtype b)
    normtype (TUncurriedFn si' as r)  = TUncurriedFn si' (map normtype as) (normtype r)
    normtype (TVariadicFn si' as v r) = TVariadicFn si' (map normtype as) (normtype v) (normtype r)
    normtype (TCon si' d r)           = TCon si' (normtype d) (normtype r)
    normtype (TSlice si' a)           = TSlice si' (normtype a)
    normtype (TVar si' a)             =
      case Prelude.lookup a ord of
        Just x -> TVar si' x
        Nothing -> error "type variable not in signature"

    tvarBindings = map (TVarBinding Missing . snd) ord

-------------------------------------------------------------------------------
-- Constraint Solver
-------------------------------------------------------------------------------

-- | Run the constraint solver
runSolve :: [Constraint] -> Either TypeError Subst
runSolve cs = runIdentity $ runExceptT $ solver st
  where st = (emptySubst, cs)

unifyMany :: SourceInfo -> [Type] -> [Type] -> Solve Subst
unifyMany _ [] [] = return emptySubst
unifyMany si (t1 : ts1) (t2 : ts2) =
  do su1 <- unifies si t1 t2
     su2 <- unifyMany si (apply su1 ts1) (apply su1 ts2)
     return (su2 `compose` su1)
unifyMany si t1 t2 = throwError $ UnificationMismatch si t1 t2

unifies :: SourceInfo -> Type -> Type -> Solve Subst
unifies _ (TVar _ v) t = v `bind` t
unifies _ t (TVar _ v) = v `bind` t
unifies _ TAny{} _ = return emptySubst
unifies si t1@(TBasic _ b1) t2@(TBasic _ b2)
  | b1 == b2 = return emptySubst
  | otherwise = throwError $ UnificationFail si t1 t2
unifies _ TUnit{} TUnit{} = return emptySubst
unifies _ t1@TCon{} t2@TCon{}
  | t1 `equalsT` t2 = return emptySubst
  | otherwise = throwError $ UnificationFail (getSourceInfo t1) t1 t2
unifies si (TFn _ t1 t2) (TFn _ t3 t4) = unifyMany si [t1, t2] [t3, t4]
unifies si (TNoArgFn _ t1) (TNoArgFn _ t2) = unifies si t1 t2
unifies si (TUncurriedFn _ as1 r1) (TUncurriedFn _ as2 r2) = do
  a <- unifyMany si as1 as2
  r <- unifies si r1 r2
  return (a `compose` r)
unifies si (TVariadicFn _ as1 v1 r1) (TVariadicFn _ as2 v2 r2) = do
  a <- unifyMany si as1 as2
  v <- unifies si v1 v2
  r <- unifies si r1 r2
  return (a `compose` v `compose` r)
unifies si (TTuple _ f1 s1 r1) (TTuple _ f2 s2 r2) = do
  f <- unifies si f1 f2
  s <- unifies si s1 s2
  r <- unifyMany si r1 r2
  return (f `compose` s `compose` r)
unifies si (TSlice _ t1) (TSlice _ t2) = unifies si t1 t2
unifies si t1 t2 = throwError $ UnificationFail si t1 t2

-- Unification solver
solver :: Unifier -> Solve Subst
solver (su, cs) =
  case cs of
    [] -> return su
    ((si, t1, t2): cs0) -> do
      su1  <- unifies si t1 t2
      solver (su1 `compose` su, apply su1 cs0)

bind ::  TVar -> Type -> Solve Subst
bind a (TVar _ v) | v == a = return emptySubst
bind a t
  | occursCheck a t = throwError $ InfiniteType (getSourceInfo t) a t
  | otherwise       = return (Subst $ Map.singleton a t)

occursCheck ::  Substitutable a => TVar -> a -> Bool
occursCheck a t = a `Set.member` ftv t
