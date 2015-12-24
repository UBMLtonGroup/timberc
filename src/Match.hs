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

module Match where

import Common
import Syntax
import Monad
import qualified List

pmc :: Exp -> [Alt Exp] -> M s Exp
pmc e alts                      = do e' <- match0 e alts
                                     return (eMatch e')

pmc' :: [Name] -> [([Pat],Rhs Exp)] -> M s Exp
pmc' ws eqs                     = do e <- match ws eqs
                                     return (eMatch e)


-- The primitive pmc constants -----------------------------------------------------------

eFatbar (EVar (Prim Fail _)) e  = e
eFatbar e (EVar (Prim Fail _))  = e
eFatbar e e'                    = foldl EAp (EVar (prim Fatbar)) [e,e']
eFail                           = EVar (prim Fail)
eCommit e                       = EAp (EVar (prim Commit)) e
eMatch e                        = case e of
                                    EAp (EVar (Prim Commit _)) e' -> e'
                                    ELet bs (EAp (EVar (Prim Commit _)) e') -> ELet bs e'
                                    _  -> EAp (EVar (prim Match)) e


fat []                          = return eFail
fat [m]                         = m
fat (m:ms)                      = do e1 <- m
                                     e2 <- fat ms
                                     return (eFatbar e1 e2)


-- Pattern-matching compiler proper -----------------------------------------------------

match0 (EVar w) alts            = match [w] [ ([p], rh) | Alt p rh <- alts ]
match0 e alts
  | all isTriv alts             = return (ECase e [ Alt p (RExp (eCommit e)) | Alt p (RExp e) <- alts ])
  | otherwise                   = do w <- newNamePos tempSym e
                                     e' <- match0 (EVar w) alts
                                     return (ELet [BEqn (LFun w []) (RExp e)] e')
  where isTriv (Alt (ECon _) (RExp _))  = True
        isTriv _                        = False


match ws eqs                    = fat (match1 ws eqs)

match1 ws []                    = []
match1 [] (([],rhs):eqs)        = matchRhs rhs : match1 [] eqs
match1 (w:ws) eqs
  | all isVarEq eqs             = match1 ws (map f eqs)
  where f (EVar v : ps, rh)     = (ps, subst (v +-> EVar w) rh)
match1 ws (eq:eqs)
  | isSigVarEq eq               = matchVar ws eq : match1 ws eqs
  | isLitEq eq                  = matchLits ws [eq] eqs
  | isERecEq eq                 = matchRecs ws [eq] eqs
  | otherwise                   = matchCons ws [prepConEq eq] eqs


isLitEq (p:ps,rh)               = isELit p

isVarEq (p:ps,rh)               = isEVar p

isSigVarEq (p:ps,rh)            = isESigVar p

isERecEq (p:ps,rh)              = isERec p

isConEq (p:ps,rh)               = isEConApp p



matchVar (w:ws) (EVar v:ps, rh) = match ws [(ps, subst (v +-> EVar w) rh)]
matchVar (w:ws) (ESig (EVar v) t : ps, rh)
                                = match ws [(ps, RWhere rh bs)]
  where bs                      = [BSig [v] t, BEqn (LFun v []) (RExp (EVar w))]


matchLits ws eqs (eq:eqs')
  | isLitEq eq                  = matchLits ws (eq:eqs) eqs'
matchLits ws eqs eqs'           = matchLit ws (reverse eqs) : match1 ws eqs'


matchLit (w:ws) eqs             = do alts <- mapM matchAlt lits
                                     return (ECase (EVar w) alts)
  where lits                    = nub [ l | (ELit l : ps, rhs) <- eqs ]
        matchAlt l              = do e' <- match ws eqs'
                                     return (Alt (ELit l) (RExp e'))
          where eqs'            = [ (ps,rhs) | (ELit l' : ps, rhs) <- eqs, l'==l ]

matchRecs ws eqs (eq:eqs')
  | isERecEq eq                 = matchRecs ws (eq:eqs) eqs'
matchRecs ws eqs eqs'           = matchRec ws (reverse eqs) : match1 ws eqs'

matchRec (w:ws) eqs             = do vs <- newNamesPos tempSym fs
                                     e <- match (vs ++ ws) (map matchAlt eqs)
                                     return (foldr ELet e (zipWith mkEqn vs fs))
  where ERec _ fs               = head (fst (head eqs))
        mkEqn v (Field l _)     = [BEqn (LFun v []) (RExp (ESelect (EVar w) l))]
        matchAlt (ERec _ fs:ps,rh)
                                = (map patOf fs++ps,rh)
        patOf (Field _ p)       = p
 
prepConEq (p:ps,rhs)            = (c, ps', ps, rhs)
  where (ECon c, ps')           = eFlat p


matchCons ws ceqs (eq:eqs')
  | isConEq eq                  = matchCons ws (prepConEq eq : ceqs) eqs'
matchCons ws ceqs eqs'          = matchCon ws (reverse ceqs) : match1 ws eqs'


matchCon (w:ws) ceqs            = do alts <- mapM matchAlt cs
                                     return (ECase (EVar w) alts)
  where cs                      = nub [ c | (c,_,_,_) <- ceqs ]
        matchAlt c              = do vs <- newNamesPos tempSym (maxPat [] 0 eqs_c)
                                     e  <- match (vs++ws) (map (mkeq vs) eqs_c)
                                     return (Alt (ECon c) (RExp (eLam (map EVar vs) e)))
          where eqs_c           = [ (ps', ps, rhs) | (c',ps',ps,rhs) <- ceqs, c==c' ]
                maxPat ps _ []  = ps
                maxPat ps n ((ps',_,_) : ceqs)
                   |length ps' > n = maxPat ps' (length ps') ceqs
                   |otherwise      = maxPat ps n ceqs
--                arity_c         = maximum [ length ps' | (ps', ps, rhs) <- eqs_c ]
        mkeq vs (ps',ps,rhs)    = (ps'++vs' ++ ps, rAp rhs vs')
          where vs'             = map EVar (drop (length ps') vs)


matchRhs (RExp e)               = return (eCommit e)
matchRhs (RWhere rhs bs)        = do e <- matchRhs rhs
                                     return (ELet bs e)
matchRhs (RGrd gs)              = fat [ matchQuals qs e | GExp qs e <- gs ]


matchQuals [] e                 = return (eCommit e)
matchQuals (QGen p e' : qs) e   = match0 e' [Alt p (RGrd [GExp qs e])]
matchQuals (QLet bs : qs) e     = do e' <- matchQuals qs e
                                     return (ELet bs e')
matchQuals (QExp e' : qs) e     = matchQuals (QGen true e' : qs) e

