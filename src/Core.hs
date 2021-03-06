{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses, FlexibleContexts, DeriveDataTypeable #-}

-- The Timber compiler <timber-lang.org>
--
-- Copyright 2008-2009 Johan Nordlander <nordland@csee.ltu.se>
-- All rights reserved.
-- 
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
-- 
-- 3. Neither the names of the copyright holder and any identified
--    contributors, nor the names of their affiliations, may be used to 
--    endorse or promote products derived from this software without 
--    specific prior written permission.
-- 
-- THIS SOFTWARE IS PROVIDED BY THE CONTRIBUTORS ``AS IS'' AND ANY EXPRESS
-- OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR
-- ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
-- STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
-- ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.

module Core where

import Common
import PP
import Data.Typeable
import Data.Binary
import Control.Monad


data Module     = Module Name [(Bool,Name)] [Default Scheme] Types [Name] [Binds]
                deriving  (Eq,Show)

data Types      = Types   KEnv Decls
                deriving  (Eq,Show)

data Binds      = Binds   Bool TEnv Eqns
                deriving  (Eq,Show)

--type Default    = (Bool,Name,Name)

type PEnv       = TEnv

type TEnv       = Map Name Scheme

type CEnv       = Map Name Constr

type Decls      = Map Name Decl

type Eqns       = Map Name Exp

data Decl       = DData     [Name] [Scheme] CEnv
                | DRec Bool [Name] [Scheme] TEnv
                | DType     [Name] Type
                deriving  (Eq,Show)

type PScheme    = Scheme

type Pred       = Type

data Scheme     = Scheme  Rho [PScheme] KEnv
                deriving  (Eq,Show,Typeable)

data Constr     = Constr  [Scheme] [PScheme] KEnv
                deriving (Eq,Show)

data Rho        = R       Type
                | F       [Scheme] Rho
                deriving (Eq,Show,Typeable)

data Type       = TId     Name
                | TVar    TVar
                | TFun    [Type] Type
                | TAp     Type Type
                deriving  (Eq,Show,Typeable)

type Alt        = (Pat, Exp)

data Pat        = PCon    Name
                | PLit    Lit
                | PWild
                deriving (Eq,Show)

data Exp        = ECon    Name
                | ESel    Exp Name
                | EVar    Name
                | ELam    TEnv Exp
                | EAp     Exp [Exp]
                | ELet    Binds Exp
                | ECase   Exp [Alt]
                | ERec    Name Eqns
                | ELit    Lit

                | EAct    Exp Exp
                | EReq    Exp Exp
                | ETempl  Name Type TEnv Cmd
                | EDo     Name Type Cmd
                deriving (Eq,Show)

data Cmd        = CGen    Name Type Exp Cmd
                | CAss    Name Exp Cmd
                | CLet    Binds Cmd
                | CRet    Exp
                | CExp    Exp
                deriving (Eq,Show)


litType (LInt _ i)              = TId (prim Int)
litType (LRat _ r)              = TId (prim Float)
litType (LChr _ c)              = TId (prim Char)
litType (LStr _ s)              = TAp (TId (prim LIST)) (TId (prim Char)) --internalError0 "Core.litType LStr"


monoRestrict rec sc (ELet bs e)
  | isEncoding bs               = monoRestrict rec sc e
monoRestrict _ _ (EAp e _)
  | isNew e                     = True
monoRestrict _ _ (ELam _ _)     = False
monoRestrict _ _ (EAct _ _)     = False
monoRestrict _ _ (EReq _ _)     = False
monoRestrict _ _ (ETempl _ _ _ _) = False
monoRestrict _ _ (EDo _ _ _)    = False
monoRestrict _ _ (EVar x)       = False
monoRestrict rec sc _           = rec && null (ctxt sc)


isNew (ELet bs e)
  | isEncoding bs               = isNew e
isNew (EVar (Prim New _))       = True
isNew _                         = False

tupleKind n                     = foldr KFun Star (replicate n Star)


tupleType n                     = Scheme (tFun' (map scheme ts) t) [] (vs `zip` repeat Star)
  where vs                      = take n abcSupply
        ts                      = map TId vs
        t                       = tAp (TId (tuple n)) ts


newTVar k                       = fmap TVar (newTV k)


nullCon                         = Constr [] [] []


isLitPat (PLit _)               = True
isLitPat _                      = False

isConPat (PCon _)               = True
isConPat _                      = False

eLet [] [] e                    = e
eLet te eq e                    = ELet (Binds False te eq) e

eLet' [] e                      = e
eLet' (bs:bss) e                = ELet bs (eLet' bss e)

cLet' [] c                      = c
cLet' (bs:bss) c                = CLet bs (cLet' bss c)

eLam [] e                       = e
eLam te e                       = ELam te e

eAbs (ELam te e)                = (te,e)
eAbs e                          = ([],e)

eAp e []                        = e
eAp e es                        = EAp e es

eAp1 e1 e2                      = EAp e1 [e2]

eAp2 (EAp e es) es'             = eAp2 e (es++es')
eAp2 e es                       = EAp e es

eFlat (EAp e es)                = (e, es)
eFlat e                         = (e,[])

eHead (EAp e e')                = eHead e
eHead e                         = e

nAp n f es                      = f es1 : es2
  where (es1,es2)               = splitAt n es

tAp t ts                        = foldl TAp t ts

tAp' i vs                       = tAp (TId i) (map TId vs)

tFun [] rh                      = rh
tFun scs rh                     = F scs rh

tFun' scs t                     = tFun scs (R t)

tFlat t                         = flat t []
  where flat (TAp t t') ts      = flat t (t':ts)
        flat t ts               = (t,ts)


tHead (TAp t t')                = tHead t
tHead t                         = t

tId (TId i)                     = i

isTVar (TVar _)                 = True
isTVar _                        = False


a `sub` b                       = TFun [a] b


isSub' p                        = isSub (body p)


isSub (TFun [l] u)              = True
isSub _                         = False

isClass' p                      = isClass (body p)

isClass c                       = not (isSub c)


subs (TFun [l] u)               = (l,u)
subs t                          = internalError "subs of" t

subsyms p                       = (tId (tHead t), tId (tHead t'))
  where (t,t')                  = subs (body p)

lowersym p                      = fst (subsyms p)
uppersym p                      = snd (subsyms p)

headsym                         = tId . tHead . body

funArgs (F ts rh)               = ts
funArgs rh                      = []


body (Scheme rh _ _)            = body' rh
  where body' (R c)             = c
        body' (F _ rh)          = body' rh

ctxt (Scheme _ ps _)            = ps

quant (Scheme _ _ ke)           = ke

scheme t                        = Scheme (R t) [] []
scheme' t                       = Scheme t [] []
pscheme p                       = Scheme (R p) [] []
pscheme' p ps ke                = Scheme (R p) ps ke


splitInsts (Binds r pe eq)      = (Binds False pe1 eq1, Binds r pe2 eq2)
  where (pe1,pe2)               = partition (isSub' . snd) pe
        (eq1,eq2)               = partition ((`elem` dom pe1) . fst) eq


ksigsOf (Types ke ds)           = ke

tdefsOf (Types ke ds)           = ds

tsigsOf (Binds _ te es)         = te

tsigsOf'                        = foldr (\bs -> ((tsigsOf bs) ++)) []

eqnsOf (Binds _ te es)          = es

isRec (Binds r _ _)             = r

catDecls ds1 ds2                = Types (ksigsOf ds1 ++ ksigsOf ds2) (tdefsOf ds1 ++ tdefsOf ds2)

catBinds bs1 bs2                = Binds (isRec bs1 || isRec bs2) (tsigsOf bs1 ++ tsigsOf bs2) (eqnsOf bs1 ++ eqnsOf bs2)

concatBinds                     = foldr catBinds nullBinds

nullDecls                       = Types [] []

nullBinds                       = Binds True [] []

clash (Binds r te es)           = not r && dom es `overlaps` evars es


altPats                         = map fst
altRhss                         = map snd

oplus eqs eqs'                  = filter ((`notElem` vs) . fst) eqs ++ eqs'
  where vs                      = dom eqs'


-- One-way matching -----------------------------------------------------
-- Only apply when types are known to match!! ---------------------------


matchTs []                              = nullSubst
matchTs ((t,TVar n):eqs)                = matchTs (subst s eqs) @@ s
  where s                               = n +-> t
matchTs ((TAp t u,TAp t' u'):eqs)       = matchTs ((t,t'):(u,u'):eqs)
matchTs ((TId c,TId c'):eqs)            = matchTs eqs
matchTs ((TFun ts t,TFun ts' t'):eqs)   = matchTs ((t,t') : ts `zip` ts' ++ eqs)
matchTs _                               = internalError0 "Core.match"


-- Equality up to renaming ----------------------------------------------

equalTs []                              = True
equalTs ((TVar n, t@(TVar n')):eqs)
  | n == n'                             = equalTs eqs
  | otherwise                           = equalTs (subst (n +-> t) eqs)
equalTs ((TAp t u, TAp t' u'):eqs)      = equalTs ((t,t'):(u,u'):eqs)
equalTs ((TId c,TId c'):eqs)
  | c == c'                             = equalTs eqs
equalTs ((TFun ts t,TFun ts' t'):eqs)
  | length ts == length ts'             = equalTs ((t,t') : ts `zip` ts' ++ eqs)
equalTs eqs                             = False


-- Simple equality check (modulo function type representation) ----------------

sameType sc t0                          = case schemeToType sc of
                                            Just t  -> t == t0
                                            Nothing -> False

schemeToType (Scheme rh [] [])          = rhoToType rh
schemeToType _                          = Nothing

rhoToType (R t)                         = return t
rhoToType (F scs rh)                    = do ts <- mapM schemeToType scs
                                             t <- rhoToType rh
                                             return (TFun ts t)


-- Free variables (Exp) -------------------------------------------------------------

instance Ids Binds where
    idents (Binds rec te eqns)
      | rec                     = idents eqns \\ dom eqns
      | otherwise               = idents eqns

instance Ids Exp where
    idents (EVar v)             = [v]
    idents (ESel e l)           = idents e
    idents (ELam te e)          = idents e \\ dom te
    idents (EAp e es)           = idents e ++ idents es
    idents (ELet bs e)          = idents bs ++ (idents e \\ bvars bs)
    idents (ECase e alts)       = idents e ++ idents alts
    idents (ERec c eqs)         = idents eqs
    idents (EAct e e')          = idents e ++ idents e'
    idents (EReq e e')          = idents e ++ idents e'
    idents (ETempl x t te c)    = idents c \\ (x : dom te)
    idents (EDo x t c)          = filter (not . isState) (idents c \\ [x])
    idents _                    = []

instance Ids Alt where
    idents (p,e)                = idents e


instance Ids Cmd where
    idents (CLet bs c)          = idents bs ++ (idents c \\ bvars bs)
    idents (CGen x t e c)       = idents e ++ (idents c \\ [x])
    idents (CAss x e c)         = idents e ++ idents c
    idents (CRet e)             = idents e
    idents (CExp e)             = idents e


-- Substitutions (Exp) --------------------------------------------------------------

-- Note! This substitution algorithm does not alpha convert!
-- Only use when variables are known not to clash

instance Subst Binds Name Exp where
    subst s (Binds r te eqns)   = Binds r te (subst s eqns)
    
instance Subst Exp Name Exp where
    subst [] e                  = e
    subst s (EVar v)            = case lookup v s of
                                      Just e  -> e
                                      Nothing -> EVar v
    subst s (ESel e l)          = ESel (subst s e) l
    subst s (ELam te e)         = ELam te (subst s e)
    subst s (EAp e es)          = EAp (subst s e) (subst s es)
    subst s (ELet bs e)         = ELet (subst s bs) (subst s e)
    subst s (ECase e alts)      = ECase (subst s e) (subst s alts)
    subst s (ERec c eqs)        = ERec c (subst s eqs)
    subst s (EAct e e')         = EAct (subst s e) (subst s e')
    subst s (EReq e e')         = EReq (subst s e) (subst s e')
    subst s (ETempl x t te c)   = ETempl x t te (subst s c)
    subst s (EDo x t c)         = EDo x t (subst s c)
    subst s e                   = e

instance Subst Cmd Name Exp where
    subst s (CLet bs c)         = CLet (subst s bs) (subst s c)
    subst s (CAss x e c)        = CAss x (subst s e) (subst s c)
    subst s (CGen x t e c)      = CGen x t (subst s e) (subst s c)
    subst s (CRet e)            = CRet (subst s e)
    subst s (CExp e)            = CExp (subst s e)

instance Subst Exp a b => Subst Alt a b where
    subst s (p,rh)              = (p, subst s rh)

instance Subst (Exp, Exp) Name Exp where
    subst s (e,e')              = (subst s e, subst s e')


instance Subst Binds TVar Type where
    subst s (Binds r te eqns)   = Binds r (subst s te) (subst s eqns)

instance Subst Exp TVar Type where
    subst [] e                  = e
    subst s (ESel e l)          = ESel (subst s e) l
    subst s (ELam te e)         = ELam (subst s te) (subst s e)
    subst s (EAp e es)          = EAp (subst s e) (subst s es)
    subst s (ELet bs e)         = ELet (subst s bs) (subst s e)
    subst s (ECase e alts)      = ECase (subst s e) (subst s alts)
    subst s (ERec c eqs)        = ERec c (subst s eqs)
    subst s (EAct e e')         = EAct (subst s e) (subst s e')
    subst s (EReq e e')         = EReq (subst s e) (subst s e')
    subst s (ETempl x t te c)   = ETempl x (subst s t) (subst s te) (subst s c)
    subst s (EDo x t c)         = EDo x (subst s t) (subst s c)
    subst s e                   = e

instance Subst Cmd TVar Type where
    subst s (CLet bs c)         = CLet (subst s bs) (subst s c)
    subst s (CAss x e c)        = CAss x (subst s e) (subst s c)
    subst s (CGen x t e c)      = CGen x (subst s t) (subst s e) (subst s c)
    subst s (CRet e)            = CRet (subst s e)
    subst s (CExp e)            = CExp (subst s e)



instance Subst Binds Name Type where
    subst s (Binds r te eqns)   = Binds r (subst s te) (subst s eqns)

instance Subst Exp Name Type where
    subst [] e                  = e
    subst s (ESel e l)          = ESel (subst s e) l
    subst  s (ELam te e)         = ELam (subst s te) (subst s e)
    subst s (EAp e es)          = EAp (subst s e) (subst s es)
    subst s (ELet bs e)         = ELet (subst s bs) (subst s e)
    subst s (ECase e alts)      = ECase (subst s e) (subst s alts)
    subst s (ERec c eqs)        = ERec c (subst s eqs)
    subst s (EAct e e')         = EAct (subst s e) (subst s e')
    subst s (EReq e e')         = EReq (subst s e) (subst s e')
    subst s (ETempl x t te c)   = ETempl x (subst s t) (subst s te) (subst s c)
    subst s (EDo x t c)         = EDo x (subst s t) (subst s c)
    subst s e                   = e

instance Subst Cmd Name Type where
    subst s (CLet bs c)         = CLet (subst s bs) (subst s c)
    subst s (CAss x e c)        = CAss x (subst s e) (subst s c)
    subst s (CGen x t e c)      = CGen x (subst s t) (subst s e) (subst s c)
    subst s (CRet e)            = CRet (subst s e)
    subst s (CExp e)            = CExp (subst s e)

instance Subst Scheme Name Name where
    subst s (Scheme rh ps ke)   = Scheme (subst s rh) (subst s ps) (map (subKE s) ke)
      where subKE s (n,k)       = case lookup n s of
                                    Just n' -> (n',k)
                                    Nothing -> (n,k)

instance Subst Rho Name Name where
    subst s (R t)               = R (subst s t)
    subst s (F scs rh)          = F (subst s scs) (subst s rh)

instance Subst Type Name Name  where
    subst s (TId c)             = case lookup c s of
                                    Just c' -> TId c'
                                    Nothing -> TId c
    subst s (TAp t t')          = TAp (subst s t) (subst s t')
    subst s (TFun ts t)         = TFun (subst s ts) (subst s t)
    subst s (TVar n)            = TVar n
    

-- Type identifiers ---------------------------------------------------------

instance Ids Decl where
    idents (DData _ bs cs)      = idents bs ++ idents cs
    idents (DRec _ _ bs ss)     = idents bs ++ idents ss
    idents (DType _ t)          = idents t

instance Ids Constr where
    idents (Constr ts ps ke)    = idents ts ++ idents ps

instance Ids Type where
    idents (TId c)              = [c]
    idents (TVar _)             = []
    idents (TAp t t')           = idents t ++ idents t'
    idents (TFun ts t)          = idents ts ++ idents t

instance Ids Scheme where
    idents (Scheme rh ps ke)    = (idents rh ++ idents ps) \\ dom ke
    
instance Ids Rho where
    idents (R t)                = idents t
    idents (F scs rh)           = idents scs ++ idents rh

instance Subst Type Name Type where
    subst s (TId c)             = case lookup c s of
                                    Just t -> t
                                    Nothing -> TId c
    subst s (TVar n)            = TVar n
    subst s (TAp t t')          = TAp (subst s t) (subst s t')
    subst s (TFun ts t)         = TFun (subst s ts) (subst s t)

instance Subst Scheme Name Type where
    subst s (Scheme rh ps ke)   = Scheme (subst s rh) (subst s ps) ke

instance Subst Rho Name Type where
    subst s (R t)               = R (subst s t)
    subst s (F scs rh)          = F (subst s scs) (subst s rh)

instance Subst (Type,Type) Name Type where
    subst s (t1,t2)             = (subst s t1, subst s t2)
    
instance Subst (Scheme,Scheme) Name Type where
    subst s (s1,s2)             = (subst s s1, subst s s2)
                

-- Type variables --------------------------------------------------------------

instance TVars Type where
    tvars (TId c)               = []
    tvars (TVar n)              = [n]
    tvars (TAp t t')            = tvars t ++ tvars t'
    tvars (TFun ts t)           = tvars ts ++ tvars t

instance TVars Scheme where
    tvars (Scheme t ps ke)      = tvars t ++ tvars ps

instance TVars Rho where
    tvars (R t)                 = tvars t
    tvars (F scs rh)            = tvars scs ++ tvars rh

instance Subst Type TVar Type where
    subst [] t                  = t
    subst s (TId c)             = TId c
    subst s (TVar n)            = case lookup n s of
                                    Just t -> t
                                    Nothing -> TVar n
    subst s (TAp t t')          = TAp (subst s t) (subst s t')
    subst s (TFun ts t)         = TFun (subst s ts) (subst s t)

instance Subst Scheme TVar Type where
    subst [] sc                 = sc
    subst s sc@(Scheme t ps ke) = Scheme (subst s t) (subst s ps) ke
  

instance Subst Rho TVar Type where
    subst s (R t)               = R (subst s t)
    subst s (F scs rh)          = F (subst s scs) (subst s rh)

instance Subst (Type,Type) TVar Type where
    subst s (t,t')              = (subst s t, subst s t')


instance Subst (Scheme,Scheme) TVar Type where
    subst s (sc,sc')            = (subst s sc, subst s sc')
    
    
-- Kind variables ----------------------------------------------------------------

instance Subst Decl Int Kind where
    subst s (DData vs bs cs)    = DData vs (subst s bs) (subst s cs)
    subst s (DRec i vs bs ss)   = DRec i vs (subst s bs) (subst s ss)
    subst s (DType vs t)        = DType vs (subst s t)

instance Subst Constr Int Kind where
    subst s (Constr ts ps ke)   = Constr (subst s ts) (subst s ps) (subst s ke)
  
instance Subst Scheme Int Kind where
    subst s (Scheme rh ps ke)  = Scheme (subst s rh) (subst s ps) (subst s ke)

instance Subst Rho Int Kind where
    subst s (R t)               = R (subst s t)
    subst s (F scs rh)          = F (subst s scs) (subst s rh)

instance Subst Type Int Kind where
    subst s (TAp t t')          = TAp (subst s t) (subst s t')
    subst s (TFun ts t)         = TFun (subst s ts) (subst s t)
    subst s (TId c)             = TId c
    subst s (TVar (TV (n,k)))   = TVar (TV (n, subst s k))
    

-- Alpha conversion -------------------------------------------------------------

class AlphaConv a where
    ac                          :: Map Name Name -> a -> M x a


alphaConvert e | mustAc e       = ac nullSubst e
               | otherwise      = return e

mustAc (ELam te e)              = True
mustAc (ELet bs e)              = True
mustAc (EDo x tx c)             = True
mustAc (ETempl x tx te c)       = True
mustAc (EAp e es)               = any mustAc (e:es)
mustAc (ESel e l)               = mustAc e
mustAc (ERec c eqs)             = any mustAc (rng eqs)
mustAc (EReq e1 e2)             = any mustAc [e1,e2]
mustAc (EAct e1 e2)             = any mustAc [e1,e2]
mustAc (ECase e alts)           = any mustAc (e:rng alts)
mustAc e                        = False


instance AlphaConv a => AlphaConv [a] where
    ac s xs                     = mapM (ac s) xs

instance (AlphaConv a, AlphaConv b) => AlphaConv (a,b) where
    ac s (p,e)                  = liftM2 (,) (ac s p) (ac s e)

instance AlphaConv Name where
    ac s x                      = case lookup x s of
                                    Just x' -> return x'
                                    _       -> return x

instance AlphaConv Binds where
    ac s (Binds r te eqs)       = liftM2 (Binds r) (ac s te) (ac s eqs)
    
instance AlphaConv Exp where
    ac s (ELit l)               = return (ELit l)
    ac s (EVar x)               = liftM EVar (ac s x)
    ac s (ECon k)               = return (ECon k)
    ac s (ESel e l)             = liftM (`ESel` l) (ac s e)
    ac s (ELam te e)            = do s' <- extSubst s (dom te)
                                     liftM2 ELam (ac s' te) (ac s' e)
    ac s (EAp e es)             = liftM2 EAp (ac s e) (mapM (ac s) es)
    ac s (ELet bs e)            = do s' <- extSubst s (bvars bs)
                                     liftM2 ELet (ac s' bs) (ac s' e)
    ac s (ERec c eqs)           = liftM (ERec c) (ac s eqs)
    ac s (ECase e alts)         = liftM2 ECase (ac s e) (ac s alts)
    ac s (EReq e1 e2)           = liftM2 EReq (ac s e1) (ac s e2)
    ac s (EAct e1 e2)           = liftM2 EAct (ac s e1) (ac s e2)
    ac s (EDo x tx c)           = do s' <- extSubst s [x]
                                     liftM3 EDo (ac s' x) (ac s' tx) (ac s' c)
    ac s (ETempl x tx te c)     = do s' <- extSubst s (x : dom te)
                                     liftM4 ETempl (ac s' x) (ac s' tx) (ac s' te) (ac s' c)
        
instance AlphaConv Pat where
    ac s p                      = return p

instance AlphaConv Cmd where
    ac s (CRet e)               = liftM CRet (ac s e)
    ac s (CExp e)               = liftM CExp (ac s e)
    ac s (CGen x tx e c)        = do s' <- extSubst s [x]
                                     liftM4 CGen (ac s' x) (ac s' tx) (ac s' e) (ac s' c)
    ac s (CAss x e c)           = liftM3 CAss (ac s x) (ac s e) (ac s c)
    ac s (CLet bs c)            = do s' <- extSubst s (bvars bs)
                                     liftM2 CLet (ac s' bs) (ac s' c)

instance AlphaConv Type where
    ac s (TId n)                = case lookup n s of
                                    Just n'       -> return (TId n')
                                    _ | isVar n   -> newTVar Star   -- not quite correct, really need an env to find kind of n
                                                                    -- But we're past kind errors anyway when we alphaconvert...
                                      | otherwise -> return (TId n)
    ac s (TFun t ts)            = liftM2 TFun (ac s t) (ac s ts)
    ac s (TAp t u)              = liftM2 TAp (ac s t) (ac s u)
    ac s (TVar n)               = newTVar (tvKind n)


instance AlphaConv Rho where
    ac s (R t)                  = liftM R (ac s t)
    ac s (F ts t)               = liftM2 F (ac s ts) (ac s t)

instance AlphaConv Scheme where
    ac s (Scheme t ps ke)       = do s' <- extSubst s (dom ke)
                                     liftM3 Scheme (ac s' t) (ac s' ps) (ac s' ke)
    
instance AlphaConv Kind where
    ac s k                      = return k
    

extSubst s xs                   = do s' <- mapM ext xs
                                     return (s'++s)
  where ext x                   = do n <- newNum
                                     return (x, {-annotGenerated-} x { tag = n })


-- Refresh free unification variables -----------------------------------------------

class Refresh a where
    refresh                     :: a -> M x a

instance Refresh a => Refresh [a] where
    refresh xs                  = mapM refresh xs
    
instance Refresh Type where
    refresh (TVar (TV (_,k)))   = newTVar k
    refresh (TFun t ts)         = liftM2 TFun (refresh t) (refresh ts)
    refresh (TAp t u)           = liftM2 TAp (refresh t) (refresh u)
    refresh t                   = return t

instance Refresh Rho where
    refresh (R t)               = liftM R (refresh t)
    refresh (F ts t)            = liftM2 F (refresh ts) (refresh t)

instance Refresh Scheme where
    refresh (Scheme t ps ke)    = liftM3 Scheme (refresh t) (refresh ps) (return ke)
    
                                     

-- Bound variables --------------------------------------------------------------

instance BVars Binds where
    bvars (Binds r te eqns)     = dom eqns

                 

-- System F encodings ============================================================

-- Encode a System F type application term
encodeTApp [] e                 = return e
encodeTApp ts e                 = do xs <- newNames tappSym (length ts)
                                     let te = xs `zip` map scheme ts
                                         eq = xs `zip` map EVar xs
                                     return (ELet (Binds True te eq) e)

isTAppEncoding (Binds r te _)   = r && isTApp (head (dom te))

tAppTypes (Binds _ te _)        = map body (rng te)


-- Encode a System F type abstraction term
encodeTAbs [] e                 = return e
encodeTAbs ke e                 = do x <- newName tabsSym
                                     let te = [(x,Scheme (R (TId (prim UNITTYPE))) [] ke)]
                                     return (ELet (Binds True te [(x,EVar x)]) e)

isTAbsEncoding (Binds r te _)   = r && isTAbs (head (dom te))

tAbsVars (Binds _ te _)         = dom (quant (head (rng te)))


isEncoding bs                   = isTAppEncoding bs || isTAbsEncoding bs


class Erase a where
    erase               ::  a -> a

instance Erase a => Erase [a] where
    erase xs                    = map erase xs

instance Erase a => Erase (Name,a) where
    erase (x,e)                 = (x, erase e)

instance Erase Exp where
    erase (ESel e l)            = ESel (erase e) l
    erase (ELam te e)           = ELam (erase te) (erase e)
    erase (EAp e es)            = EAp (erase e) (erase es)
    erase (ELet bs e)
      | isEncoding bs           = erase e
      | otherwise               = ELet (erase bs) (erase e)
    erase (ECase e alts)        = ECase (erase e) (erase alts)
    erase (ERec c eqs)          = ERec c (erase eqs)
    erase (EAct e e')           = EAct (erase e) (erase e')
    erase (EReq e e')           = EReq (erase e) (erase e')
    erase (ETempl x t te c)     = ETempl x (erase t) (erase te) (erase c)
    erase (EDo x t c)           = EDo x (erase t) (erase c)
    erase e                     = e

instance Erase Alt where
    erase (p,e)                 = (p, erase e)

instance Erase Binds where
    erase (Binds r te es)       = Binds r (erase te) (erase es)
    
instance Erase Cmd where
    erase (CLet bs c)           = CLet (erase bs) (erase c)
    erase (CAss x e c)          = CAss x (erase e) (erase c)
    erase (CGen x t e c)        = CGen x (erase t) (erase e) (erase c)
    erase (CRet e)              = CRet (erase e)
    erase (CExp e)              = CExp (erase e)
    
instance Erase Type where
    erase (TAp t t')            = TAp (erase t) (erase t')
    erase (TFun ts t)           = TFun (erase ts) (erase t)
    erase (TId n)               = TId n
    erase (TVar _)              = TId (prim Int)

instance Erase Rho where
    erase (F ts t)              = F (erase ts) (erase t)
    erase (R t)                 = R (erase t)

instance Erase Scheme where
    erase (Scheme rh ps ke)     = Scheme (erase rh) (erase ps) ke


-- Printing ==================================================================

-- Modules -------------------------------------------------------------------

instance Pr Module where
    pr (Module i ns xs ds is bss) = text "module" <+> prId i <+> text "where"
                                    $$ prImports ns $$ prDefaults xs $$ pr ds $$ prInstance is $$ vpr bss

prImports []                      = empty
prImports (i : is)                = prI i $$ prImports is
  where prI(True,n)               = text "import" <+> pr n
        prI(False,n)              = text "use" <+> pr n

prDefaults []                     = empty
prDefaults ns                     = text "default" <+> hpr ',' ns

prInstance []                     = empty
prInstance ns                     = text "instance" <+> hpr ',' ns

instance Pr (Module,a) where
  pr (m,_)                       = pr m

-- Type declarations ---------------------------------------------------------

instance Pr Types where
    pr (Types ke ds)            = vpr ke $$ vpr ds

instance Pr (Name, Decl) where
    pr (i, DType vs t)          = text "type" <+> prId i <+> hsep (map prId vs) 
                                  <+> text "=" <+> pr t
    pr (i, DData vs ts cs)      = text "data" <+> prId i <+> hsep (map prId vs) 
                                  <+> prSubs ts <+> prConstrs cs
    pr (i, DRec isC vs ts ss)   = text kwd <+> prId i <+> hsep (map prId vs) 
                                  <+> prSups ts <+> prEq ss $$ nest 4 (vpr ss)
      where kwd                 = if isC then "typeclass " else "struct"

prEq []                         = empty
prEq _                          = text "where"


-- Instances ---------------------------------------------------------------

prInsts (Binds r te eqs)        = vcat (map prInst te) $$ vpr eqs

prInst (i, p)                   = text "instance" <+> prId i <+> text "::" <+> prPScheme 0 p


-- Bindings -----------------------------------------------------------------

instance Pr Binds where
--    pr (Binds True te eqns)     = text "rec" $$ vpr te $$ vpr eqns
    pr (Binds _ te eqns)        = vpr te $$ vpr eqns
    
instance Pr (Name, Scheme) where
    pr (v, sc)                  = prId v <+> text "::" <+> pr sc
--      where sc'                 = subst s sc
--            s                   = map f (tyvars sc)
--            f v@(Name s n m a)  = (v, Name ('_':s) n m a)
--            f v                 = (v,v)
                                  
instance Pr (Name, Exp) where
    pr (v, e)                   = prId v <+> text "=" <+> pr e

instance Pr [(Name, Scheme)] where
    pr ss                       = vpr ss
        

prTop te                        = vcat (map pr' te)
  where pr' (v,sc)              = prId v <+> text "::" <+> pr sc


-- Sub/supertypes -----------------------------------------------------------

prSups []                       = empty
prSups ts                       = char '<' <+> hpr ',' ts

prSubs []                       = empty
prSubs ts                       = char '>' <+> hpr ',' ts

    
-- Constructors ------------------------------------------------------------

prConstrs []                    = empty
prConstrs (c:cs)                = vcat (char '=' <+> pr c : map ((char '|' <+>) . pr) cs)

instance Pr (Name,Constr) where
    pr (i, Constr ts ps ke)     = prId i <+> hsep (map (prn 1) ts) <+> prContext ps ke


-- Predicates --------------------------------------------------------------

prContext [] []                 = empty
prContext ps ke                 = text "\\\\" <+> preds
  where preds                   = hsep (punctuate comma (map (prPScheme 1) ps ++ map prKind ke))

prKind (n,Star)                 = prId n
prKind (n,k)                    = prId n <+> text "::" <+> pr k

prPScheme 0 (Scheme p ps ke)    = prRPred p <+> prContext ps ke
prPScheme 1 (Scheme p [] [])    = prRPred p
prPScheme 1 sc                  = parens (prPScheme 0 sc)

prRPred (F [t1] t2)             = prn 1 t1 <+> text "<" <+> prn 1 t2
prRPred (R t)                   = prPred t

prPred (TFun [t1] t2)           = prn 1 t1 <+> text "<" <+> prn 1 t2
prPred t                        = pr t


-- Types -----------------------------------------------------------------

instance Pr Scheme where
    prn 0 (Scheme rh ps ke)     = prn 0 rh <+> prContext ps ke
    prn 1 (Scheme rh [] [])     = prn 1 rh
    prn n sc                    = parens (prn 0 sc)

instance Pr Rho where
    prn 0 (F scs rh)            = hsep (punctuate (text " ->") (map (prn 1) scs ++ [prn 1 rh]))
    prn 0 rh                    = prn 1 rh
    prn 1 (R t)                 = prn 1 t
    prn 1 rh                    = parens (prn 0 rh)
    
instance Pr Type where
    prn 0 (TFun ts t)           = hsep (punctuate (text " ->") (map (prn 1) (ts++[t])))
    prn 0 t                     = prn 1 t
    
    prn 1 (TAp (TId (Prim LIST _)) t) = text "[" <> prn 0 t <> text "]"
    prn 1 t@(TAp _ _)           = prTAp (tFlat t)
      where prTAp (TId (Tuple n _),ts) = text "(" <> hpr ',' ts <> text ")"
--            prTAp (t,ts)        = hang (prn 1 t) 2 (sep (map (prn 2) ts))
            prTAp (t,ts)        = prn 1 t <+> sep (map (prn 2) ts)
    prn 1 t                     = prn 2 t

    prn 2 (TId c)               = prId c
--    prn 2 (TVar _)              = text "_"
    prn 2 (TVar n)              = text "_" <> pr n

    prn 2 t                     = parens (prn 0 t)


prMaybeScheme Nothing           = empty
prMaybeScheme (Just t)          = prn 1 t


-- Substitutions -----------------------------------------------------------

instance Pr a => Pr (a, Type) where
    pr (n, t) = pr n <+> text "~" <+> pr t


-- Patterns ----------------------------------------------------------------

instance Pr Pat where
    pr (PCon k)                 = prId k
    pr (PLit l)                 = pr l
    pr (PWild)                  = text "_"
    

-- Expressions -------------------------------------------------------------

prParam (x,Scheme (R (TVar _)) [] [])
                                = prId x
prParam (x,sc)                  = parens (pr (x,sc))

instance Pr Exp where
    prn 0 (ELam te e)           = hang (char '\\' <> sep (map prParam te) <+> text "->") 4 (pr e)
    prn 0 (ELet bs e)
      | isTAppEncoding bs       = pr e <+> braces (commasep pr (tAppTypes bs))
      | isTAbsEncoding bs       = hang (text "/\\" <> sep (map prId (tAbsVars bs)) <+> text "->") 4 (pr e)
--      | isTAppEncoding bs       = pr e
--      | isTAbsEncoding bs       = pr e
      | otherwise               = text "let" $$ nest 4 (pr bs) $$ text "in" <+> pr e
    prn 0 (ECase e alts)        = text "case" <+> pr e <+> text "of" $$ 
                                       nest 2 (vpr alts)
    prn 0 (EAct e e')           = text "action@" <> prn 2 e $$
                                       nest 4 (pr e')
    prn 0 (EReq e e')           = text "request@" <> prn 2 e $$
                                       nest 4 (pr e')
    prn 0 (ETempl x t te c)     = text "class@" <> prId x $$
                                       nest 4 (vpr te) $$
                                       nest 4 (pr c)
    prn 0 (EDo x t c)           = text "do@" <> prId x <> text "::" <> pr t $$
                                       nest 4 (pr c)
    prn 0 e                     = prn 1 e

    prn 1 (EAp e@(ELet bs _) es)
      | isEncoding bs           = prn 0 e <+> sep (map (prn 2) es)
    prn 1 (EAp e es)            = prn 1 e <+> sep (map (prn 2) es)

    prn 1 e                     = prn 2 e
        
    prn 2 (ECon c)              = prId c
    prn 2 (ESel e s)            = prn 2 e <> text "." <> prId s
    prn 2 (EVar v)              = prId v
    prn 2 (ELit l)              = pr l
    prn 2 (ERec c eqs)          = prId c <+> text "{" <+> hpr ',' eqs <+> text "}"
    prn 2 e                     = parens (prn 0 e)

instance Pr Alt where
    pr (p, e)                   = pr p <+> text "->" $$ nest 4 (pr e)

instance Pr Cmd where
    pr (CLet bs c)              = pr bs $$
                                  pr c
    pr (CAss x e c)             = prId x <+> text ":=" <+> pr e $$
                                  pr c
    pr (CGen x t e c)           = prId x <+> {- text "::" <+> pr t <+> -} text "<-" <+> pr e $$
                                  pr c
    pr (CRet e)                 = text "result" <+> pr e
    pr (CExp e)                 = pr e



-- HasPos --------------------------------------------------

instance HasPos Types where
  posInfo (Types ke ds)         = between (posInfo ke) (posInfo ds)

instance HasPos Binds where
  posInfo (Binds _ te es)       = posInfo es

instance HasPos Decl where
  posInfo (DData ns ts ce)      = foldr1 between [posInfo ns, posInfo ts, posInfo ce]
  posInfo (DRec _ ns ts te)     = foldr1 between [posInfo ns, posInfo ts, posInfo te]
  posInfo (DType ns t)          = between (posInfo ns) (posInfo t)

instance HasPos Scheme where
  posInfo (Scheme r ps ke)      = foldr1 between [posInfo r, posInfo ps, posInfo ke]

instance HasPos Constr where
  posInfo (Constr ts ps ke)     = foldr1 between [posInfo ts, posInfo ps, posInfo ke]

instance HasPos Rho where
  posInfo (R t)                 = posInfo t
  posInfo (F ts r)              = between (posInfo ts) (posInfo r)

instance HasPos Type where
  posInfo (TId n)               = posInfo n
  posInfo (TVar _)              = Unknown
  posInfo (TFun ts t)           = posInfo (t : ts)
  posInfo (TAp t t')            = between (posInfo t) (posInfo t')

instance HasPos Pat where
  posInfo (PCon n)              = posInfo n
  posInfo (PLit l)              = posInfo l
  posInfo (PWild)               = Unknown

instance HasPos Exp where
  posInfo (ECon n)              = posInfo n
  posInfo (ESel e l)            = between (posInfo e) (posInfo l)
  posInfo (EVar n)              = posInfo n
  posInfo (ELam te e)           = between (posInfo (dom te)) (posInfo e)
  posInfo (EAp e es)            = foldr1 between (map posInfo (e : es))
  posInfo (ELet bs e)           = between (posInfo bs) (posInfo e)
  posInfo (ECase e as)          = foldr1 between [posInfo e, posInfo as]
  posInfo (ERec n es)           = between (posInfo n) (posInfo es)
  posInfo (ELit l)              = posInfo l
  posInfo (EAct e e')           = between (posInfo e) (posInfo e')
  posInfo (EReq e e')           = between (posInfo e) (posInfo e')
  posInfo (ETempl n t te c)     = foldr1 between [posInfo n, posInfo te, posInfo c]
  posInfo (EDo n t c)           = foldr1 between [posInfo n, posInfo c]

instance HasPos Cmd where
  posInfo (CGen n t e c)        = foldr1 between [posInfo n, posInfo e, posInfo c]
  posInfo (CAss n e c)          = foldr1 between [posInfo n, posInfo e, posInfo c]
  posInfo (CLet bs c)           = between (posInfo bs) (posInfo c)
  posInfo (CRet e)              = posInfo e
  posInfo (CExp e)              = posInfo e

  
-- Binary --------------------------------------------------

instance Binary Module where
  put (Module a b c d e f) = put a >> put b >> put c >> put d >> put e >> put f
  get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d -> get >>= \e -> get>>= \f -> return (Module a b c d e f)

instance Binary Types where
  put (Types a b) = put a >> put b
  get = get >>= \a -> get >>= \b -> return (Types a b)

instance Binary Binds where
  put (Binds a b c) = put a >> put b >> put c
  get = get >>= \a -> get >>= \b -> get >>= \c -> return (Binds a b c)

instance Binary Decl where
  put (DData a b c) = putWord8 0 >> put a >> put b >> put c
  put (DRec a b c d) = putWord8 1 >> put a >> put b >> put c >> put d
  put (DType a b) = putWord8 2 >> put a >> put b
  get = do
    tag_ <- getWord8
    case tag_ of
      0 -> get >>= \a -> get >>= \b -> get >>= \c -> return (DData a b c)
      1 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d -> return (DRec a b c d)
      2 -> get >>= \a -> get >>= \b -> return (DType a b)
      _ -> fail "no parse"

instance Binary Scheme where
  put (Scheme a b c) = put a >> put b >> put c
  get = get >>= \a -> get >>= \b -> get >>= \c -> return (Scheme a b c)

instance Binary Constr where
  put (Constr a b c) = put a >> put b >> put c
  get = get >>= \a -> get >>= \b -> get >>= \c -> return (Constr a b c)

instance Binary Rho where
  put (R a) = putWord8 0 >> put a
  put (F a b) = putWord8 1 >> put a >> put b
  get = do
    tag_ <- getWord8
    case tag_ of
      0 -> get >>= \a -> return (R a)
      1 -> get >>= \a -> get >>= \b -> return (F a b)
      _ -> fail "no parse"

instance Binary Type where
  put (TId a) = putWord8 0 >> put a
  put (TVar a) = putWord8 1 >> put a
  put (TFun a b) = putWord8 2 >> put a >> put b
  put (TAp a b) = putWord8 3 >> put a >> put b
  get = do
    tag_ <- getWord8
    case tag_ of
      0 -> get >>= \a -> return (TId a)
      1 -> get >>= \a -> return (TVar a)
      2 -> get >>= \a -> get >>= \b -> return (TFun a b)
      3 -> get >>= \a -> get >>= \b -> return (TAp a b)
      _ -> fail "no parse"

instance Binary Pat where
  put (PCon a) = putWord8 0 >> put a
  put (PLit a) = putWord8 1 >> put a
  put (PWild)  = putWord8 2
  get = do
    tag_ <- getWord8
    case tag_ of
      0 -> get >>= \a -> return (PCon a)
      1 -> get >>= \a -> return (PLit a)
      2 -> return PWild
      _ -> fail "no parse"

instance Binary Exp where
  put (ECon a) = putWord8 0 >> put a
  put (ESel a b) = putWord8 1 >> put a >> put b
  put (EVar a) = putWord8 2 >> put a
  put (ELam a b) = putWord8 3 >> put a >> put b
  put (EAp a b) = putWord8 4 >> put a >> put b
  put (ELet a b) = putWord8 5 >> put a >> put b
  put (ECase a b) = putWord8 6 >> put a >> put b
  put (ERec a b) = putWord8 7 >> put a >> put b
  put (ELit a) = putWord8 8 >> put a
  put (EAct a b) = putWord8 9 >> put a >> put b
  put (EReq a b) = putWord8 10 >> put a >> put b
  put (ETempl a b c d) = putWord8 11 >> put a >> put b >> put c >> put d
  put (EDo a b c) = putWord8 12 >> put a >> put b >> put c
  get = do
    tag_ <- getWord8
    case tag_ of
      0 -> get >>= \a -> return (ECon a)
      1 -> get >>= \a -> get >>= \b -> return (ESel a b)
      2 -> get >>= \a -> return (EVar a)
      3 -> get >>= \a -> get >>= \b -> return (ELam a b)
      4 -> get >>= \a -> get >>= \b -> return (EAp a b)
      5 -> get >>= \a -> get >>= \b -> return (ELet a b)
      6 -> get >>= \a -> get >>= \b -> return (ECase a b)
      7 -> get >>= \a -> get >>= \b -> return (ERec a b)
      8 -> get >>= \a -> return (ELit a)
      9 -> get >>= \a -> get >>= \b -> return (EAct a b)
      10 -> get >>= \a -> get >>= \b -> return (EReq a b)
      11 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d -> return (ETempl a b c d)
      12 -> get >>= \a -> get >>= \b -> get >>= \c -> return (EDo a b c)
      _ -> fail "no parse"

instance Binary Cmd where
  put (CGen a b c d) = putWord8 0 >> put a >> put b >> put c >> put d
  put (CAss a b c) = putWord8 1 >> put a >> put b >> put c
  put (CLet a b) = putWord8 2 >> put a >> put b
  put (CRet a) = putWord8 3 >> put a
  put (CExp a) = putWord8 4 >> put a
  get = do
    tag_ <- getWord8
    case tag_ of
      0 -> get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d -> return (CGen a b c d)
      1 -> get >>= \a -> get >>= \b -> get >>= \c -> return (CAss a b c)
      2 -> get >>= \a -> get >>= \b -> return (CLet a b)
      3 -> get >>= \a -> return (CRet a)
      4 -> get >>= \a -> return (CExp a)
      _ -> fail "no parse"
