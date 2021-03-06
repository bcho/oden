module Oden.Compiler.Monomorphization where

import           Control.Monad.Except
import           Control.Monad.RWS
import           Data.Map                  as Map hiding (map)
import           Data.Set                  as Set hiding (map)

import           Oden.Compiler.Environment
import           Oden.Compiler.Instantiate
import           Oden.Compiler.TypeEncoder
import qualified Oden.Core                 as Core
import           Oden.Identifier
import           Oden.Environment                as Environment
import           Oden.SourceInfo
import qualified Oden.Type.Monomorphic     as Mono
import qualified Oden.Type.Polymorphic     as Poly

data MonomorphedDefinition = MonomorphedDefinition SourceInfo Name Mono.Type (Core.Expr Mono.Type)
                           deriving (Show, Eq, Ord)

data InstantiatedDefinition =
  InstantiatedDefinition Name (Core.Expr Mono.Type)
  deriving (Show, Eq, Ord)

data MonomorphedPackage = MonomorphedPackage Core.PackageDeclaration [Core.Import] (Set InstantiatedDefinition) (Set MonomorphedDefinition)
                     deriving (Show, Eq, Ord)

data MonomorphError   = NotInScope Identifier
                      | UnexpectedPolyType SourceInfo (Core.Expr Poly.Type)
                      | MonomorphInstantiateError InstantiateError
                      deriving (Show, Eq, Ord)

data LocalBinding = LetBinding Core.NameBinding (Core.Expr Poly.Type)
                  | FunctionArgument Core.NameBinding

type LocalBindings = Map Name LocalBinding

data LetReference = LetReference Name Mono.Type Name
                 deriving (Show, Eq, Ord)

data LetInstance = LetInstance SourceInfo Core.NameBinding (Core.Expr Mono.Type)

data MonomorphState = MonomorphState { instances   :: Map (Identifier, Mono.Type) InstantiatedDefinition
                                     , monomorphed :: Map Identifier MonomorphedDefinition
                                     , environment :: CompileEnvironment
                                     }

type Monomorph a = RWST LocalBindings
                        (Set LetReference)
                        MonomorphState
                        (Except MonomorphError)
                        a

lookupIn :: CompileEnvironment -> Name -> Monomorph Core.Definition
lookupIn env name =
  case Environment.lookup name env of
      Nothing             -> throwError $ NotInScope (Unqualified name)
      Just Package{}      -> throwError $ NotInScope (Unqualified name)
      Just (Definition d) -> return d

getInEnvironment :: Identifier -> Monomorph Core.Definition
getInEnvironment q@(Qualified pkg n) = do
  env <- gets environment
  case Environment.lookup pkg env of
    Just (Package _ _ env') -> (lookupIn env' n) `catchError` onError
      where
      onError :: MonomorphError -> Monomorph Core.Definition
      onError NotInScope{} = throwError $ NotInScope q
      onError e = throwError e
    _ -> throwError (NotInScope q)
getInEnvironment (Unqualified n) = do
  env <- gets environment
  lookupIn env n

extendEnvironment :: Name -> Core.Definition -> Monomorph ()
extendEnvironment name def = do
  env <- gets environment
  modify (\s -> s { environment = env `extend` (name, Definition def) })

withBinding :: LocalBinding -> Monomorph a -> Monomorph a
withBinding b@(LetBinding (Core.NameBinding _ name) _) = local $ Map.insert name b
withBinding b@(FunctionArgument (Core.NameBinding _ name)) = local $ Map.insert name b

addInstance :: (Identifier, Mono.Type) -> InstantiatedDefinition -> Monomorph ()
addInstance key inst =
  modify (\s -> s { instances = Map.insert key inst (instances s) })

addMonomorphed :: Name -> MonomorphedDefinition -> Monomorph ()
addMonomorphed name def =
  modify (\s -> s { monomorphed = Map.insert (Unqualified name) def (monomorphed s) })

instantiateDefinition :: (Identifier, Mono.Type)
                      -> Poly.Scheme
                      -> Core.Expr Poly.Type
                      -> Monomorph Identifier
instantiateDefinition key@(pn, t) _ pe = do
  let name = encodeTypeInstance pn t
  case instantiate pe t of
    Left err -> throwError (MonomorphInstantiateError err)
    Right expr -> do
      me <- monomorph expr
      addInstance key (InstantiatedDefinition name me)
      return (Unqualified name)

getMonomorphicDefinition :: Identifier -> Mono.Type -> Monomorph Identifier
getMonomorphicDefinition ident t = do
  def <- getInEnvironment ident
  case def of
    Core.ForeignDefinition{} -> return ident
    Core.Definition _ _ (sc, pe) | Poly.isPolymorphic sc -> do
      let key = (ident, t)
      is <- gets instances
      case Map.lookup key is of
        Just (InstantiatedDefinition name _) -> return (Unqualified name)
        Nothing -> instantiateDefinition key sc pe
    Core.Definition _ pn _ -> return (Unqualified pn)

getMonomorphicLetBinding :: Name
                         -> Mono.Type
                         -> Poly.Type
                         -> Monomorph Identifier
getMonomorphicLetBinding n mt pt | not (Poly.isPolymorphicType pt) = do
  tell (Set.singleton (LetReference n mt n))
  return (Unqualified n)
getMonomorphicLetBinding n mt _ = do
  let encoded = encodeTypeInstance (Unqualified n) mt
  tell (Set.singleton (LetReference n mt encoded))
  return (Unqualified encoded)

getMonomorphic :: Identifier -> Mono.Type -> Monomorph Identifier
getMonomorphic i@(Qualified _ _) t =
  local (const Map.empty) (getMonomorphicDefinition i t)
getMonomorphic i@(Unqualified n) t = do
  binding <- Map.lookup n <$> ask
  case binding of
    Just (FunctionArgument (Core.NameBinding _ a)) ->
      return (Unqualified a)
    Just (LetBinding (Core.NameBinding _ n') e) ->
      getMonomorphicLetBinding n' t (Core.typeOf e)
    Nothing ->
      local (const Map.empty) (getMonomorphicDefinition i t)

getMonoType :: Core.Expr Poly.Type -> Monomorph Mono.Type
getMonoType e =
  either (const $ throwError (UnexpectedPolyType (getSourceInfo e) e))
         return
         (Poly.toMonomorphic (Core.typeOf e))

monomorph :: Core.Expr Poly.Type -> Monomorph (Core.Expr Mono.Type)
monomorph e@(Core.Symbol si ident _) = do
  mt <- getMonoType e
  m <- getMonomorphic ident mt
  return (Core.Symbol si m mt)
monomorph e@(Core.Subscript si s i _) = do
  mt <- getMonoType e
  ms <- monomorph s
  mi <- monomorph i
  return (Core.Subscript si ms mi mt)
monomorph e@(Core.Subslice si s (Core.Range e1 e2) _) = do
  mt <- getMonoType e
  ms <- monomorph s
  me1 <- monomorph e1
  me2 <- monomorph e2
  return (Core.Subslice si ms (Core.Range me1 me2) mt)
monomorph e@(Core.Subslice si s (Core.RangeTo i) _) = do
  mt <- getMonoType e
  ms <- monomorph s
  mi <- monomorph i
  return (Core.Subslice si ms (Core.RangeTo mi) mt)
monomorph e@(Core.Subslice si s (Core.RangeFrom i) _) = do
  mt <- getMonoType e
  ms <- monomorph s
  mi <- monomorph i
  return (Core.Subslice si ms (Core.RangeFrom mi) mt)
monomorph e@(Core.UnaryOp si o e1 _) = do
  mt <- getMonoType e
  me <- monomorph e1
  return (Core.UnaryOp si o me mt)
monomorph e@(Core.BinaryOp si o e1 e2 _) = do
  mt <- getMonoType e
  me1 <- monomorph e1
  me2 <- monomorph e2
  return (Core.BinaryOp si o me1 me2 mt)
monomorph e@(Core.Application si f p _) = do
  mt <- getMonoType e
  mf <- monomorph f
  mp <- monomorph p
  return (Core.Application si mf mp mt)
monomorph e@(Core.NoArgApplication si f _) = do
  mt <- getMonoType e
  mf <- monomorph f
  return (Core.NoArgApplication si mf mt)
monomorph e@(Core.UncurriedFnApplication si f ps _) = do
  mt <- getMonoType e
  mf <- monomorph f
  mps <- mapM monomorph ps
  return (Core.UncurriedFnApplication si mf mps mt)
monomorph e@(Core.Fn si a b _) = do
  mt <- getMonoType e
  mb <- withBinding (FunctionArgument a) (monomorph b)
  return (Core.Fn si a mb mt)
monomorph e@(Core.NoArgFn si b _) = do
  mt <- getMonoType e
  mb <- monomorph b
  return (Core.NoArgFn si mb mt)
monomorph e@(Core.Slice si es _) = do
  mt <- getMonoType e
  mes <- mapM monomorph es
  return (Core.Slice si mes mt)
monomorph e@(Core.Block si es _) = do
  mt <- getMonoType e
  mes <- mapM monomorph es
  return (Core.Block si mes mt)
monomorph e@(Core.Literal si l _) = do
  mt <- getMonoType e
  return (Core.Literal si l mt)
monomorph e@(Core.Tuple si f s r _) = do
  mt <- getMonoType e
  mf <- monomorph f
  ms <- monomorph s
  mr <- mapM monomorph r
  return (Core.Tuple si mf ms mr mt)
monomorph e@(Core.If si cond then' else' _) = do
  mt <- getMonoType e
  mCond <- monomorph cond
  mThen <- monomorph then'
  mElse <- monomorph else'
  return (Core.If si mCond mThen mElse mt)
monomorph (Core.Let si b@(Core.NameBinding bsi _) expr body _) = do
  (mBody, allRefs) <- listen (withBinding (LetBinding b expr) (monomorph body))
  let (refs, other) = Set.partition (isReferenceTo b) allRefs
  tell other
  insts <- mapM (monomorphReference expr si bsi) (Set.toList refs)
  return (unwrapLetInstances insts mBody)
  where
  isReferenceTo :: Core.NameBinding -> LetReference -> Bool
  isReferenceTo (Core.NameBinding _ n) (LetReference ln _ _) = n == ln

monomorphReference :: Core.Expr Poly.Type
                   -> SourceInfo
                   -> SourceInfo
                   -> LetReference
                   -> Monomorph LetInstance
monomorphReference e si bsi (LetReference n _ _) | not (Poly.isPolymorphicType (Core.typeOf e)) = do
  me <- monomorph e
  return (LetInstance si (Core.NameBinding bsi n) me)
monomorphReference e si bsi (LetReference _ mt mn) =
  case instantiate e mt of
    Left err -> throwError (MonomorphInstantiateError err)
    Right expr -> do
      me <- monomorph expr
      return (LetInstance si (Core.NameBinding bsi mn) me)

unwrapLetInstances :: [LetInstance] -> Core.Expr Mono.Type -> Core.Expr Mono.Type
unwrapLetInstances [] body = body
unwrapLetInstances (LetInstance si mn me:is) body =
  Core.Let si mn me (unwrapLetInstances is body) (Core.typeOf body)

monomorphDefinition :: Core.Definition -> Monomorph ()
monomorphDefinition Core.ForeignDefinition{} = return ()
monomorphDefinition d@(Core.Definition si name (Poly.Forall _ _ st, expr)) = do
  extendEnvironment name d
  case Poly.toMonomorphic st of
    Left _ -> return ()
    Right mt -> do
      mExpr <- monomorph expr
      addMonomorphed name (MonomorphedDefinition si name mt mExpr)

monomorphPackage :: CompileEnvironment -> Core.Package -> Either MonomorphError MonomorphedPackage
monomorphPackage environment' (Core.Package pkgDecl imports definitions) = do
  let st = MonomorphState { instances = Map.empty
                          , monomorphed = Map.empty
                          , environment = environment'
                          }
  (_, s, _) <- runExcept $ runRWST (mapM_ monomorphDefinition definitions) Map.empty st
  let is = Set.fromList (Map.elems (instances s))
      ms = Set.fromList (Map.elems (monomorphed s))
  return (MonomorphedPackage pkgDecl imports is ms)

compile :: CompileEnvironment -> Core.Package -> Either MonomorphError MonomorphedPackage
compile = monomorphPackage
