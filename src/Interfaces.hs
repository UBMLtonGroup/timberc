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

module Interfaces where

import Common
import List (isPrefixOf)
import Data.Binary
import Rename 
import Core
import qualified Syntax
import Decls
import PP
import qualified Core2Kindle 
import qualified Kindle 
import Termred
import qualified Config
import System
import Codec.Compression.BZip 
import qualified Data.ByteString.Lazy
import Directory

decodeCFile ti_file     = do str <- Data.ByteString.Lazy.readFile ti_file
                             return(decode(decompress str)) 

encodeCFile ti_file ifc =  Data.ByteString.Lazy.writeFile ti_file (compress(encode ifc))

{-
Reading/writing ti files without compression.

decodeCFile ti_file     = decodeFile ti_file

encodeCFile ti_file ifc = encodeFile ti_file ifc
-}

-- Data type of interface file -----------------------------------------------

data IFace = IFace { impsOf      :: [(Bool,Name)],                         -- imported/used modules
                     defaults    :: [Default Scheme],               -- exported default declarations
                     recordEnv   :: Map Name [Name],                -- exported record types and their selectors,
                     tsynEnv     :: Map Name ([Name],Syntax.Type),  -- type synonyms
                     tEnv        :: Types,                          -- Core type environment
                     insts       :: [Name],                         -- types for instances
                     valEnv      :: Binds,                          -- types for exported values (including sels and cons) and some finite eqns
                     kdeclEnv    :: Kindle.Decls                    -- Kindle form of declarations
                   }
           deriving (Show)

-- Building interface info from data collected during compilation of a module ---------------------------------
{-
Input to ifaceMod is
      - from Desugar1: exported record types with their selectors and exported type synomyms.
      - from Termred: the entire module in Core form after term reduction
      - from Core2Kindle: declarations in Kindle form.
The function checks that the public part is closed (does not mention private data) and computes
the IFace.
-}
 
ifaceMod                   :: (Map Name [Name], Map Name ([Name], Syntax.Type)) -> Module -> Kindle.Decls -> IFace
ifaceMod (rs,ss) (Module _ ns xs ds ws bss) kds
   | not(null vis2)                  = errorIds "Private types visible in interface" vis2
   | not(null ys)                    = errorTree "Public default declaration mentions private instance" (head ys)
   | otherwise                       = IFace ns xs' rs ss ds1 ws bs' kds
  where Types ke te                  = ds
        Binds r2 ts2 es2             = concatBinds bss
        xs'                          = [d | d@(Default True _ _) <- xs]
        ys                           = [d | d@(Default _ i1 i2) <- xs', isPrivate i1 || isPrivate i2 ]
        ds1                          = Types (filter exported ke ++ map (\n -> (n,Star)) vis1) (filter exported' te)
        bs'                          = Binds r2 (filter exported ts2) (filter (\ eqn -> fin eqn &&  exported eqn) (erase es2))
        (vis1,vis2)                  = partition isStateType (nub (localTypes [] (rng (tsigsOf bs'))))
        
        exported (n,_)               = isQualified n
        exported' p@(n,_)            = isQualified n && (not(isAbstract p)) --Constructors/selectors are exported
        fin (_,e)                    = isFinite e && null(filter isPrivate (constrs e))

isPrivate nm@(Name _ _ _ _)          = not(isQualified nm)
isPrivate _                          = False

isAbstract (_,DData _ _ ((c,_):_))   = isPrivate c
isAbstract (_,DRec _ _ _ ((c,_):_))  = isPrivate c
isAbstract (_,_)                     = False     -- this makes abstract types without selectors/constructors non-private...



-- Building environments in which to compile the current module -----------------------------------------------
{- 
   Input to initEnvs is a map as built by chaseIFaceFiles;
   output is four tuples of data suitable for various compiler passes.
-}
type ImportInfo a                     =  (Bool, a)


type Desugar1Env     = (Map Name [Name], Map Name Name, Map Name ([Name], Syntax.Type))
type RenameEnv       = (Map Name Name, Map Name Name, Map Name Name)
type CheckEnv        = ([Default Scheme], Types, [Name], Binds)
type KindleEnv       = Map Name Kindle.Decl

initEnvs             :: Map a (ImportInfo IFace) -> M s (Desugar1Env, RenameEnv, CheckEnv, KindleEnv)
initEnvs bms         = do ims <- mapM (mkEnv . snd) bms
                          let (rs,xs,ss,rnL,rnT,rnE,ds,ws,bs,kds) 
                               = foldr mergeMod ([],[],[],[],[],[],Types [] [],[],Binds False [] [],[]) ims
                          return ((rs,rnL,ss),(rnL,rnT,rnE),(xs,ds,ws,bs),kds)

  where mergeMod (rs1,xs1,ss1,rnL1,rnT1,rnE1,ds1,ws1,bs1,kds1)
                 (rs2,xs2,ss2,rnL2,rnT2,rnE2,ds2,ws2,bs2,kds2) 
                                     = (rs1 ++ rs2, xs1 ++ xs2, ss1 ++ ss2, mergeRenamings2 rnL1 rnL2, 
                                       mergeRenamings2 rnT1 rnT2, mergeRenamings2 rnE1 rnE2,
                                       catDecls ds1 ds2, ws1++ws2, catBinds bs1 bs2,
                                       kds1 ++ kds2)

        mkEnv (unQual,IFace ns xs rs ss ds ws bs kds)
                                     = do ks  <- renaming (dom ke)
                                          ts  <- renaming (dom te'')
                                          ls' <- renaming ls -- (concatMap snd rs)
                                          return (unMod unQual rs, xs, unMod unQual ss, unMod unQual ls',unMod unQual ks,
                                                  unMod unQual ts,ds,ws,Binds r te' es,kds)
          where Types ke ds'         = ds
                Binds r te es        = bs
                te'                  = te ++ concatMap (tenvSelCon ke) ds'
                te''                 = te  ++ concatMap (tenvCon ke) ds'
                ls                   = [ s | (_,DRec _ _ _ cs) <- ds', (s,_) <- cs, not (isGenerated s) ]
                unMod b ps           = if b then [(tag0 (dropMod c),y) | (c,y) <- ps] ++ ps else ps

-- Checking that public part is closed ---------------------------------------------------------

class LocalTypes a where 
  localTypes :: [Name] -> a -> [Name]

instance LocalTypes a => LocalTypes [a] where
  localTypes ns ds                = concatMap (localTypes ns) ds

instance LocalTypes b => LocalTypes (a,b) where
  localTypes ns (a,b)             = localTypes ns b

instance LocalTypes Scheme where
  localTypes ns (Scheme r ps ke)  = localTypes ns1 r ++ localTypes ns1 ps
    where ns1                     = ns ++ dom ke

instance LocalTypes Rho where
  localTypes ns (R t)             = localTypes ns t
  localTypes ns (F ss r)          = localTypes ns ss ++ localTypes ns r

instance LocalTypes Type where
  localTypes ns (TId n) 
     | n `elem` ns || not (isPrivate n) = []
     | otherwise                  = [n]
  localTypes _ (TVar t)           = internalError0 ("Interfaces.localTypes: TVar in interface file")
  localTypes ns (TFun ts t)       = localTypes ns (t : ts)
  localTypes ns (TAp t1 t2)       = localTypes ns [t1, t2]

instance LocalTypes Decl where
  localTypes ns (DData vs ps cs)  = localTypes ns1 ps ++ localTypes ns1 cs
    where ns1                     = ns ++ vs
  localTypes ns (DRec _ vs ps ss) = localTypes ns1 ps ++ localTypes ns1 ss
    where ns1                     = ns ++ vs
  localTypes ns (DType vs t)      = localTypes (ns ++ vs) t

instance LocalTypes Constr where
  localTypes ns (Constr ts ps ke) = localTypes ns1 ts ++ localTypes ns1 ps
    where ns1                     = ns ++ dom ke
       
-- Binary -------------------------------------------------------------------------------

instance Binary IFace  where
  put (IFace a b c d e f g h) = put a >> put b >> put c >> put d >> put e >> put f >> put g >> put h
  get = get >>= \a -> get >>= \b -> get >>= \c -> get >>= \d -> get >>= \e -> get >>= \f ->  
        get >>= \g -> get >>= \h -> return (IFace a b c d e f g h)

-- Printing -----------------------------------------------------------------------------

instance Pr IFace where
  pr (IFace ns xs rs ss ds1 ws bs kds) =
                                  text "Imported/used modules: " <+> prImports ns $$
                                  text "Default declarations: " <+> hpr ',' xs $$
                                  text ("Record types and their selectors: "++show rs) $$
                                  text "Type synonyms: " <+> hsep (map (prId . fst) ss) $$ 
                                  text "\nType definitions\n----------------" $$ pr ds1 $$ 
                                  text "\nTop level bindings\n------------------" $$ pr (simpVars bs)  $$
                                  text "\nKindle declarations\n-------------------" $$ vcat (map pr kds)
                                  
-- prPair (n,t)                      = prId n <+> text "::" <+> pr t
   where simpVars (Binds rec te eqns) = Binds rec (map sV te) eqns
         
sV (n,t@(Scheme rh ps ke))            = case zip (filter isTypevar (idents (Scheme rh ps []))) abcSupply of
                                          [] -> (n,t)
                                          s ->  (n,subst s t) 
  where isTypevar n                   = isGenerated n && not (isStateType n)
listIface clo f                   = do (ifc,f) <- decodeModule clo f
                                       --writeAPI f ifc
                                       let modul = rmSuffix ".ti" f
                                           htmlfile = modul++".html"
                                       res <- checkUpToDate f htmlfile
                                       if not res then do
                                          writeAPI modul ifc
                                          system (Config.pager clo ++" " ++ htmlfile)
                                        else system (Config.pager clo ++" " ++ htmlfile)
  where checkUpToDate tiFile htmlFile = do html_exists <- Directory.doesFileExist htmlFile
                                           if not html_exists then
                                              return False
                                            else do
                                              ti_time  <- Directory.getModificationTime tiFile
                                              html_time  <- Directory.getModificationTime htmlFile
                                              return (ti_time <= html_time)


writeAPI modul ifc             = writeFile (modul ++ ".html") (render(toHTML modul (ifc :: IFace)))

toHTML n (IFace ns xs rs ss ds ws bs _) = text "<html><body>\n" $$
                                          text ("<h2>API for module "++n++"</h2>\n") $$
                                          section ns "Imported modules" prImports $$
                                          section xs "Default declarations" (hpr ',') $$
                                          section ke' "Kind declarations" (pr . flip Types []) $$
                                          section ds' "Type declarations" (pr . Types [] . map addSubs) $$
                                          section te' "Toplevel declarations" (prTop . stripTopdecls) $$
                                          text "</html>"
                      
  where section xs header f             = if null xs 
                                           then empty 
                                           else text ("<h4>"++header++"</h4>\n<pre>") $$ f xs $$ text "</pre>"
        
        Types ke ds'                    = ds
        ke'                             = [(n,k) | (n,k) <- ke, notElem n (dom ds')]
        Binds _ te _                    = bs
        addSubs (n,DData vs _ cs)       = (n,DData vs (map (\(_,Constr (s:_) _ _) -> s) cs1) cs2)
         where (cs1,cs2)                = partition (isGenerated . fst) cs
        addSubs (n,DRec b vs _ ss)      = (n,DRec b vs (map snd ss1) ss2)
         where (ss1, ss2)               = partition (isGenerated . fst) (map stripStar ss)
        addSubs d                       = d
        stripStar (n,Scheme rh ps ke)   = (n,Scheme rh ps (filter (( /= Star) . snd) ke))
        te'                             = map (sV . stripStar)  (filter (not . isGenerated . fst) te)
        stripTopdecls te                = bs1 ++ bs2
         where (bs1,bs2)                = partition (flip elem ws . fst ) te
                                                  
        
decodeModule clo f                      = (do ifc <- decodeCFile f
                                              putStrLn ("[reading " ++ show f ++ "]")
                                              return (ifc,f)) `catch`  (\e -> do let libf = Config.libDir clo ++ "/" ++ f
                                                                                 ifc <- decodeCFile libf
                                                                                 putStrLn ("[reading " ++ show libf ++ "]")
                                                                                 return (ifc,libf))

