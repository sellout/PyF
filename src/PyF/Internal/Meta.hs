{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE ViewPatterns #-}

module PyF.Internal.Meta (toExp, baseDynFlags) where

#if MIN_VERSION_ghc(9,2,0)
import GHC.Hs.Type (HsWildCardBndrs (..), HsType (..), HsSigType(HsSig), sig_body)
#elif MIN_VERSION_ghc(9,0,0)
import GHC.Hs.Type (HsWildCardBndrs (..), HsType (..), HsImplicitBndrs(HsIB), hsib_body)
#elif MIN_VERSION_ghc(8,10,0)
import GHC.Hs.Types (HsWildCardBndrs (..), HsType (..), HsImplicitBndrs (HsIB, hsib_body))
#elif MIN_VERSION_ghc(8,6,0)
import HsTypes (HsWildCardBndrs (..), HsType (..), HsImplicitBndrs (HsIB), hsib_body)
#else
import HsTypes (HsAppType (..), HsWildCardBndrs (..), HsType (..), HsImplicitBndrs (HsIB), hsib_body)
import TyCoRep (Type (..))
#endif

#if MIN_VERSION_ghc(8,10,0)
import GHC.Hs.Expr as Expr
import GHC.Hs.Extension as Ext
import GHC.Hs.Pat as Pat
import GHC.Hs.Lit
#else
import HsExpr as Expr
import HsExtension as Ext
import HsPat as Pat
import HsLit
#endif

import qualified Data.ByteString as B
import qualified Language.Haskell.TH.Syntax as GhcTH
import qualified Language.Haskell.TH.Syntax as TH
import PyF.Internal.ParserEx (fakeLlvmConfig, fakeSettings)

#if MIN_VERSION_ghc(9,0,0)
import GHC.Types.SrcLoc
import GHC.Types.Name
import GHC.Types.Name.Reader
import GHC.Data.FastString
#if MIN_VERSION_ghc(9,2,0)
import GHC.Utils.Outputable (ppr)
import GHC.Types.Basic (Boxity(..))
import GHC.Types.SourceText (il_value, rationalFromFractionalLit)
import GHC.Driver.Ppr (showSDocDebug)
#else
import GHC.Utils.Outputable (ppr, showSDocDebug)
import GHC.Types.Basic (il_value, fl_value, Boxity(..))
#endif
import GHC.Driver.Session (DynFlags, xopt_set, defaultDynFlags)
import qualified GHC.Unit.Module as Module
#else
import SrcLoc
import Name
import RdrName
import FastString
import Outputable (ppr, showSDocDebug)
import BasicTypes (il_value, fl_value, Boxity(..))
import DynFlags (DynFlags, xopt_set, defaultDynFlags)
import qualified Module
#endif

import GHC.Stack

#if MIN_VERSION_ghc(9,2,0)
-- TODO: why this disapears in GHC >= 9.2?
fl_value = rationalFromFractionalLit
#endif

toLit :: HsLit GhcPs -> TH.Lit
toLit (HsChar _ c) = TH.CharL c
toLit (HsCharPrim _ c) = TH.CharPrimL c
toLit (HsString _ s) = TH.StringL (unpackFS s)
toLit (HsStringPrim _ s) = TH.StringPrimL (B.unpack s)
toLit (HsInt _ i) = TH.IntegerL (il_value i)
toLit (HsIntPrim _ i) = TH.IntPrimL i
toLit (HsWordPrim _ i) = TH.WordPrimL i
toLit (HsInt64Prim _ i) = TH.IntegerL i
toLit (HsWord64Prim _ i) = TH.WordPrimL i
toLit (HsInteger _ i _) = TH.IntegerL i
toLit (HsRat _ f _) = TH.FloatPrimL (fl_value f)
toLit (HsFloatPrim _ f) = TH.FloatPrimL (fl_value f)
toLit (HsDoublePrim _ f) = TH.DoublePrimL (fl_value f)

#if MIN_VERSION_ghc(8, 6, 0) && !MIN_VERSION_ghc(9,0,0)
toLit (XLit _) = noTH "toLit" "XLit"
#endif

toLit' :: OverLitVal -> TH.Lit
toLit' (HsIntegral i) = TH.IntegerL (il_value i)
toLit' (HsFractional f) = TH.RationalL (fl_value f)
toLit' (HsIsString _ fs) = TH.StringL (unpackFS fs)

toType :: HsType GhcPs -> TH.Type
toType (HsWildCardTy _) = TH.WildCardT
#if MIN_VERSION_ghc(8, 6, 0)
toType (HsTyVar _ _ n) =
  let n' = unLoc n
   in if isRdrTyVar n'
        then TH.VarT (toName n')
        else TH.ConT (toName n')
#else
toType (HsTyVar _ n) =
  let n' = unLoc n
   in if isRdrTyVar n'
        then TH.VarT (toName n')
        else TH.ConT (toName n')
toType (HsAppsTy [unLoc -> HsAppPrefix (unLoc -> ty)]) = toType ty
#endif
toType t = todo "toType" (showSDocDebug (baseDynFlags []) . ppr $ t)

toName :: RdrName -> TH.Name
toName n = case n of
  (Unqual o) -> TH.mkName (occNameString o)
  (Qual m o) -> TH.mkName (Module.moduleNameString m <> "." <> occNameString o)
  (Orig m o) -> error "orig"
  (Exact nm) -> case getOccString nm of
    "[]" -> '[]
    "()" -> '()
    _    -> error "toName: exact name encountered"

toFieldExp :: a
toFieldExp = undefined

toPat :: DynFlags -> Pat.Pat GhcPs -> TH.Pat
#if MIN_VERSION_ghc(8, 6, 0)
toPat _dynFlags (Pat.VarPat _ (unLoc -> name)) = TH.VarP (toName name)
#else
toPat _dynFlags (Pat.VarPat (unLoc -> name)) = TH.VarP (toName name)
#endif
toPat dynFlags p = todo "toPat" (showSDocDebug dynFlags . ppr $ p)

toExp :: DynFlags -> Expr.HsExpr GhcPs -> TH.Exp
#if MIN_VERSION_ghc(8, 6, 0)
toExp _ (Expr.HsVar _ n) =
  let n' = unLoc n
   in if isRdrDataCon n'
        then TH.ConE (toName n')
        else TH.VarE (toName n')
#else
toExp _ (Expr.HsVar n) =
  let n' = unLoc n
   in if isRdrDataCon n'
        then TH.ConE (toName n')
        else TH.VarE (toName n')
#endif
#if MIN_VERSION_ghc(9,0,0)
toExp _ (Expr.HsUnboundVar _ n)              = TH.UnboundVarE (TH.mkName . occNameString $ n)
#elif MIN_VERSION_ghc(8, 6, 0)
toExp _ (Expr.HsUnboundVar _ n)              = TH.UnboundVarE (TH.mkName . occNameString . Expr.unboundVarOcc $ n)
#else
toExp _ (Expr.HsUnboundVar n)                = TH.UnboundVarE (TH.mkName . occNameString . Expr.unboundVarOcc $ n)
#endif
toExp _ Expr.HsIPVar {} = noTH "toExp" "HsIPVar"
#if MIN_VERSION_ghc(8, 6, 0)
toExp _ (Expr.HsLit _ l) = TH.LitE (toLit l)
toExp _ (Expr.HsOverLit _ OverLit {ol_val}) = TH.LitE (toLit' ol_val)
toExp d (Expr.HsApp _ e1 e2) = TH.AppE (toExp d . unLoc $ e1) (toExp d . unLoc $ e2)
#else
toExp _ (Expr.HsLit l) = TH.LitE (toLit l)
toExp _ (Expr.HsOverLit OverLit {ol_val}) = TH.LitE (toLit' ol_val)
toExp d (Expr.HsApp e1 e2) = TH.AppE (toExp d . unLoc $ e1) (toExp d . unLoc $ e2)
#endif
#if MIN_VERSION_ghc(9,2,0)
toExp d (Expr.HsAppType _ e HsWC {hswc_body}) = TH.AppTypeE (toExp d . unLoc $ e) (toType . unLoc $ hswc_body)
toExp d (Expr.ExprWithTySig _ e HsWC{hswc_body=unLoc -> HsSig{sig_body}}) = TH.SigE (toExp d . unLoc $ e) (toType . unLoc $ sig_body)
#elif MIN_VERSION_ghc(8,8,0)
toExp d (Expr.HsAppType _ e HsWC {hswc_body}) = TH.AppTypeE (toExp d . unLoc $ e) (toType . unLoc $ hswc_body)
toExp d (Expr.ExprWithTySig _ e HsWC{hswc_body=HsIB{hsib_body}}) = TH.SigE (toExp d . unLoc $ e) (toType . unLoc $ hsib_body)
#elif MIN_VERSION_ghc(8,6,0)
toExp d (Expr.HsAppType HsWC {hswc_body} e) = TH.AppTypeE (toExp d . unLoc $ e) (toType . unLoc $ hswc_body)
toExp d (Expr.ExprWithTySig HsWC{hswc_body=HsIB{hsib_body}} e) = TH.SigE (toExp d . unLoc $ e) (toType . unLoc $ hsib_body)
#else
toExp d (Expr.HsAppType e HsWC {hswc_body}) = TH.AppTypeE (toExp d . unLoc $ e) (toType . unLoc $ hswc_body)
toExp d (Expr.ExprWithTySig e HsWC{hswc_body=HsIB{hsib_body}}) = TH.SigE (toExp d . unLoc $ e) (toType . unLoc $ hsib_body)
#endif
#if MIN_VERSION_ghc(8, 6, 0)
toExp d (Expr.OpApp _ e1 o e2) = TH.UInfixE (toExp d . unLoc $ e1) (toExp d . unLoc $ o) (toExp d . unLoc $ e2)
toExp d (Expr.NegApp _ e _) = TH.AppE (TH.VarE 'negate) (toExp d . unLoc $ e)
-- NOTE: for lambda, there is only one match
toExp d (Expr.HsLam _ (Expr.MG _ (unLoc -> (map unLoc -> [Expr.Match _ _ (map unLoc -> ps) (Expr.GRHSs _ [unLoc -> Expr.GRHS _ _ (unLoc -> e)] _)])) _)) = TH.LamE (fmap (toPat d) ps) (toExp d e)
#else
toExp d (Expr.OpApp e1 o _ e2) = TH.UInfixE (toExp d . unLoc $ e1) (toExp d . unLoc $ o) (toExp d . unLoc $ e2)
toExp d (Expr.NegApp e _) = TH.AppE (TH.VarE 'negate) (toExp d . unLoc $ e)
-- NOTE: for lambda, there is only one match
toExp d (Expr.HsLam (Expr.MG (unLoc -> (map unLoc -> [Expr.Match _ (map unLoc -> ps) (Expr.GRHSs [unLoc -> Expr.GRHS _ (unLoc -> e)] _)])) _ _ _)) = TH.LamE (fmap (toPat d) ps) (toExp d e)
#endif
-- toExp (Expr.Let _ bs e)                       = TH.LetE (toDecs bs) (toExp e)
-- toExp (Expr.If _ a b c)                       = TH.CondE (toExp a) (toExp b) (toExp c)
-- toExp (Expr.MultiIf _ ifs)                    = TH.MultiIfE (map toGuard ifs)
-- toExp (Expr.Case _ e alts)                    = TH.CaseE (toExp e) (map toMatch alts)
-- toExp (Expr.Do _ ss)                          = TH.DoE (map toStmt ss)
-- toExp e@Expr.MDo{}                            = noTH "toExp" e
#if MIN_VERSION_ghc(9, 2, 0)
toExp d (Expr.ExplicitTuple _ args boxity) = ctor tupArgs
#elif MIN_VERSION_ghc(8, 6, 0)
toExp d (Expr.ExplicitTuple _ (map unLoc -> args) boxity) = ctor tupArgs
#else
toExp d (Expr.ExplicitTuple (map unLoc -> args) boxity) = ctor tupArgs
#endif
  where
#if MIN_VERSION_ghc(8, 6, 0)
    toTupArg (Expr.Present _ e) = Just $ unLoc e
#else
    toTupArg (Expr.Present e) = Just $ unLoc e
#endif
    toTupArg (Expr.Missing _) = Nothing
#if MIN_VERSION_ghc(8, 6, 0)
    toTupArg _ = error "impossible case"
#endif

    ctor = case boxity of
      Boxed -> TH.TupE
      Unboxed -> TH.UnboxedTupE

#if MIN_VERSION_ghc(8,10,0)
    tupArgs = fmap ((fmap (toExp d)) . toTupArg) args
#else
    tupArgs = case traverse toTupArg args of
      Nothing -> error "Tuple section are not supported by template haskell < 8.10"
      Just args -> fmap (toExp d) args
#endif

-- toExp (Expr.List _ xs)                        = TH.ListE (fmap toExp xs)
#if MIN_VERSION_ghc(8, 6, 0)
toExp d (Expr.HsPar _ e) = TH.ParensE (toExp d . unLoc $ e)
toExp d (Expr.SectionL _ (unLoc -> a) (unLoc -> b)) = TH.InfixE (Just . toExp d $ a) (toExp d b) Nothing
toExp d (Expr.SectionR _ (unLoc -> a) (unLoc -> b)) = TH.InfixE Nothing (toExp d a) (Just . toExp d $ b)
toExp _ (Expr.RecordCon _ name HsRecFields {rec_flds}) =
  TH.RecConE (toName . unLoc $ name) (fmap toFieldExp rec_flds)
#else
toExp d (Expr.HsPar e) = TH.ParensE (toExp d . unLoc $ e)
toExp d (Expr.SectionL (unLoc -> a) (unLoc -> b)) = TH.InfixE (Just . toExp d $ a) (toExp d b) Nothing
toExp d (Expr.SectionR (unLoc -> a) (unLoc -> b)) = TH.InfixE Nothing (toExp d a) (Just . toExp d $ b)
toExp _ (Expr.RecordCon name _ _ HsRecFields {rec_flds}) =
  TH.RecConE (toName . unLoc $ name) (fmap toFieldExp rec_flds)
#endif
-- toExp (Expr.RecUpdate _ e xs)                 = TH.RecUpdE (toExp e) (fmap toFieldExp xs)
-- toExp (Expr.ListComp _ e ss)                  = TH.CompE $ map convert ss ++ [TH.NoBindS (toExp e)]
--  where
--   convert (Expr.QualStmt _ st)                = toStmt st
--   convert s                                   = noTH "toExp ListComp" s
-- toExp (Expr.ExpTypeSig _ e t)                 = TH.SigE (toExp e) (toType t)
#if MIN_VERSION_ghc(9, 2, 0)
toExp d (Expr.ExplicitList _ (map unLoc -> args)) = TH.ListE (map (toExp d) args)
#else
toExp d (Expr.ExplicitList _ _ (map unLoc -> args)) = TH.ListE (map (toExp d) args)
#endif
toExp d (Expr.ArithSeq _ _ e) = TH.ArithSeqE $ case e of
  (From a) -> TH.FromR (toExp d $ unLoc a)
  (FromThen a b) -> TH.FromThenR (toExp d $ unLoc a) (toExp d $ unLoc b)
  (FromTo a b) -> TH.FromToR (toExp d $ unLoc a) (toExp d $ unLoc b)
  (FromThenTo a b c) -> TH.FromThenToR (toExp d $ unLoc a) (toExp d $ unLoc b) (toExp d $ unLoc c)
#if MIN_VERSION_ghc(9, 2, 0)
toExp _ (HsOverLabel _ lbl) = TH.LabelE (unpackFS lbl)
#elif MIN_VERSION_ghc(8, 6, 0)
-- It's not quite clear what to do in case when overloaded syntax is
-- enabled thus match on Nothing
toExp _ (HsOverLabel _ Nothing lbl) = TH.LabelE (unpackFS lbl)
#else
-- It's not quite clear what to do in case when overloaded syntax is
-- enabled thus match on Nothing
toExp _ (HsOverLabel Nothing lbl) = TH.LabelE (unpackFS lbl)
#endif
toExp dynFlags e = todo "toExp" (showSDocDebug dynFlags . ppr $ e)

todo :: (HasCallStack, Show e) => String -> e -> a
todo fun thing = error . concat $ [moduleName, ".", fun, ": not implemented: ", show thing]

noTH :: (HasCallStack, Show e) => String -> e -> a
noTH fun thing = error . concat $ [moduleName, ".", fun, ": no TemplateHaskell for: ", show thing]

moduleName :: String
moduleName = "PyF.Internal.Meta"

baseDynFlags :: [GhcTH.Extension] -> DynFlags
baseDynFlags exts =
  let enable = GhcTH.TemplateHaskellQuotes : exts
   in foldl xopt_set (defaultDynFlags fakeSettings fakeLlvmConfig) enable
