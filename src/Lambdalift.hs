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

module Lambdalift(lambdalift) where

import Monad
import Common
import Kindle
import PP


lambdalift ds m                 = localStore (llModule ds m)


data Env                        = Env { decls      :: Decls,                    -- global type declarations
                                        thisVars   :: [Name],                   -- variables reachable through "this"
                                        locals     :: ATEnv,                    -- non-global value names in scope
                                        expansions :: Map Name ([Name],[Name])  -- non-global functions and their added type/term parameters
                                      }

nullEnv                         = Env { decls = primDecls, 
                                        thisVars = [],
                                        locals = [],
                                        expansions = []
                                      }

addDecls ds env                         = env { decls = ds ++ decls env }

setThisVars xs env                      = env { thisVars = xs }

addLocals te env                        = env { locals = te ++ locals env }

addExpansions exps env                  = env { expansions = exps ++ expansions env }


-- Convert a module
llModule dsi (Module m ns ds bs)        = do bs <- mapM (llBind env0) bs
                                             s <- currentStore
                                             return (Module m ns (ds ++ declsOfStore s) (bs ++ bindsOfStore s))
  where env0                            = addDecls (ds ++ dsi) nullEnv


declsOfStore s                          = [ d | Left d <- s ]

bindsOfStore s                          = [ b | Right b <- s ]


-- Convert a binding
llBind env (x, Fun vs t te c)           = do c <- llCmd (addLocals te env) c
                                             return (x, Fun vs t te c)
llBind env (x, Val t e)                 = do e <- llExp env e
                                             return (x, Val t e)


{- Lambda-lifting a set of recursive bindings:

   \v ->                                                letrec f r v x = ... r ... v ...
   letrec f x = ... r ... v ...                                g r v y = ... f r v e ...
          r   = { a = ... g e ... }         ==>         in \v ->
          g y = ... f e ...                             letrec r  = { a = ... g r v e ... }
   in f e                                               in f r v e
-}

{- Closing a struct with function fields:

   \v ->                                                \v ->
   { f x = ... v ...                                    { f x = ... this.v ...
     w   = ... v ... }                      ==>           w   = ... v ...
                                                          v   = v }
-}

-- Convert a command
llCmd env (CBind r bs c)                = do vals' <- mapM (llBind env') vals
                                             funs' <- mapM (llBind (setThisVars [] env')) funs
                                             mapM_ liftFun funs'
                                             c' <- llCmd env2 c
                                             return (cBindR r vals' c')
  where (vals,funs)                     = partition isVal bs
        free0                           = evars funs
        free1                           = free0 ++ concat [ xs | (f,(_,xs)) <- expansions env, f `elem` free0 ]
        fte                             = locals (if r then env1 else env) `restrict` free1
        vs1                             = concat [ vs | (f,(vs,_)) <- expansions env, f `elem` free0 ]
        tvs                             = nub (typevars funs ++ typevars fte ++ vs1)
        env1                            = addLocals (mapSnd typeOf' vals) env
        env2                            = addExpansions (dom funs `zip` repeat (tvs, dom fte)) env1
        env'                            = if r then env2 else env
        liftFun (x, Fun vs t te c)      = addToStore (Right (x, Fun (tvs++vs) t (fte++te) c))
llCmd env (CRet e)                      = liftM CRet (llExp env e)
llCmd env (CRun e c)                    = liftM2 CRun (llExp env e) (llCmd env c)
llCmd env (CUpd x e c)                  = liftM2 (CUpd x) (llExp env e) (llCmd env c)
llCmd env (CUpdS e x e' c)              = do e <- llExp env e
                                             liftM2 (CUpdS e x) (llExp env e') (llCmd env c)
llCmd env (CUpdA e i e' c)              = liftM4 CUpdA (llExp env e) (llExp env i) (llExp env e') (llCmd env c)
llCmd env (CSwitch e alts)              = liftM2 CSwitch (llExp env e) (mapM (llAlt env) alts)
llCmd env (CSeq c c')                   = liftM2 CSeq (llCmd env c) (llCmd env c')
llCmd env (CBreak)                      = return CBreak
llCmd env (CRaise e)                    = liftM CRaise (llExp env e)
llCmd env (CWhile e c c')               = liftM3 CWhile (llExp env e) (llCmd env c) (llCmd env c')
llCmd env (CCont)                       = return CCont


-- Convert a switch alternative
llAlt env (ACon x vs te c)              = liftM (ACon x vs te) (llCmd (addLocals te env) c)
llAlt env (ALit l c)                    = liftM (ALit l) (llCmd env c)
llAlt env (AWild c)                     = liftM AWild (llCmd env c)


-- Convert an expression
llExp env (ECall x ts es)               = do es <- mapM (llExp env) es
                                             case lookup x (expansions env) of
                                                Just (vs,xs) -> return (ECall x (map tVar vs ++ ts) (map (mkEVar env) xs ++ es))
                                                Nothing -> return (ECall x ts es)
llExp env ee@(ENew n ts bs)
  | null fte && null fvs                = liftM (ENew n ts) (mapM (llBind env) bs)
  | otherwise                           = do n' <- extendStruct n vs fvs te (mapSnd ValT fte)
                                             vals' <- mapM (llBind env) vals
                                             funs' <- mapM (llBind (setThisVars (dom fte) env)) funs
                                             -- tr ("lift ENew: " ++ render (pr (TCon n ts)) ++ "  fvs: " ++ show fvs ++ "   new: " ++ show n')
                                             return (ECast (TCon n ts) (ENew n' (ts ++ map tVar fvs) (vals' ++ funs' ++ map close fte)))
  where (vals,funs)                     = partition isVal bs
        free0                           = evars funs
        free1                           = free0 ++ concat [ xs | (f,(_,xs)) <- expansions env, f `elem` free0 ]
        fte                             = locals env `restrict` free1
        vs1                             = concat [ vs | (f,(vs,_)) <- expansions env, f `elem` free0 ]
        fvs                             = nub (typevars funs ++ typevars fte ++ vs1)
        Struct vs te _                  = lookup' (decls env) n   -- NOTE: n can't be a tuple or a cons if fte/fvs are nonempty...
        close (x,t)                     = (x, Val t (mkEVar env x))


llExp env (EVar x)                      = return (mkEVar env x)
llExp env (EThis)                       = return (EThis)
llExp env (ELit l)                      = return (ELit l)
llExp env (ESel e l)                    = liftM (flip ESel l) (llExp env e)
llExp env (EEnter e f ts es)            = do e <- llExp env e
                                             liftM (EEnter e f ts) (mapM (llExp env) es)
llExp env (ECast t e)                   = liftM (ECast t) (llExp env e)


mkEVar env x                            = if x `elem` thisVars env then ESel EThis x else EVar x

extendStruct n vs vs' te te'
  | not (null (intersect vs vs'))       = do vs1 <- newNames tyvarSym (length vs)
                                             let te1 = subst (vs `zip` map tVar vs1) te
                                                 s1 = Struct (vs1++vs') (te1++te') (Extends n)
                                             n <- newName typeSym
                                             addToStore (Left (n, s1))
                                             return n
  | otherwise                           = do s <- currentStore
                                             case findStruct s0 (declsOfStore s) of
                                               Just n  -> return n
                                               Nothing -> do n <- newName typeSym
                                                             addToStore (Left (n, s0))
                                                             return n
  where s0                              = Struct (vs++vs') (te++te') (Extends n)
