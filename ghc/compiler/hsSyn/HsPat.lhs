%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[PatSyntax]{Abstract Haskell syntax---patterns}

\begin{code}
#include "HsVersions.h"

module HsPat (
	InPat(..),
	OutPat(..),

	unfailablePats, unfailablePat,
	patsAreAllCons, isConPat,
	patsAreAllLits,	isLitPat,
	irrefutablePat,
	collectPatBinders
    ) where

import Ubiq

-- friends:
import HsLit		( HsLit )
import HsLoop		( HsExpr )

-- others:
import Id		( GenId, dataConSig )
import Maybes		( maybeToBool )
import Name		( pprOp, pprNonOp )
import Outputable	( interppSP, interpp'SP, ifPprShowAll )
import PprStyle		( PprStyle(..) )
import Pretty
import TyCon		( maybeTyConSingleCon )
import PprType		( GenType )
\end{code}

Patterns come in distinct before- and after-typechecking flavo(u)rs.
\begin{code}
data InPat name
  = WildPatIn				-- wild card
  | VarPatIn	    name		-- variable
  | LitPatIn	    HsLit		-- literal
  | LazyPatIn	    (InPat name)	-- lazy pattern
  | AsPatIn	    name		-- as pattern
		    (InPat name)
  | ConPatIn	    name		-- constructed type
		    [InPat name]
  | ConOpPatIn	    (InPat name)
		    name
		    (InPat name)

  -- We preserve prefix negation and parenthesis for the precedence parser.

  | NegPatIn	    (InPat name)	-- negated pattern
  | ParPatIn        (InPat name)	-- parenthesised pattern

  | ListPatIn	    [InPat name]	-- syntactic list
					-- must have >= 1 elements
  | TuplePatIn	    [InPat name]	-- tuple

  | RecPatIn	    name 		-- record
		    [(name, InPat name, Bool)]	-- True <=> source used punning

data OutPat tyvar uvar id
  = WildPat	    (GenType tyvar uvar)	 	    	-- wild card

  | VarPat	    id				-- variable (type is in the Id)

  | LazyPat	    (OutPat tyvar uvar id)	-- lazy pattern

  | AsPat	    id				-- as pattern
		    (OutPat tyvar uvar id)

  | ConPat	    Id				-- Constructor is always an Id
		    (GenType tyvar uvar)    	-- the type of the pattern
		    [(OutPat tyvar uvar id)]

  | ConOpPat	    (OutPat tyvar uvar id)	-- just a special case...
		    Id
		    (OutPat tyvar uvar id)
		    (GenType tyvar uvar)
  | ListPat		 	    		-- syntactic list
		    (GenType tyvar uvar)	-- the type of the elements
   	    	    [(OutPat tyvar uvar id)]

  | TuplePat	    [(OutPat tyvar uvar id)]	-- tuple
						-- UnitPat is TuplePat []

  | RecPat	    Id 				-- record constructor
		    (GenType tyvar uvar)    	-- the type of the pattern
		    [(id, OutPat tyvar uvar id, Bool)]	-- True <=> source used punning

  | LitPat	    -- Used for *non-overloaded* literal patterns:
		    -- Int#, Char#, Int, Char, String, etc.
		    HsLit
		    (GenType tyvar uvar) 	-- type of pattern

  | NPat	    -- Used for *overloaded* literal patterns
		    HsLit			-- the literal is retained so that
						-- the desugarer can readily identify
						-- equations with identical literal-patterns
		    (GenType tyvar uvar) 	-- type of pattern, t
   	    	    (HsExpr tyvar uvar id (OutPat tyvar uvar id))
						-- of type t -> Bool; detects match

  |  DictPat	    -- Used when destructing Dictionaries with an explicit case
		    [id]			-- superclass dicts
		    [id]			-- methods
\end{code}

\begin{code}
instance (Outputable name, NamedThing name) => Outputable (InPat name) where
    ppr = pprInPat

pprInPat :: (Outputable name, NamedThing name) => PprStyle -> InPat name -> Pretty

pprInPat sty (WildPatIn)	= ppStr "_"
pprInPat sty (VarPatIn var)	= pprNonOp sty var
pprInPat sty (LitPatIn s)	= ppr sty s
pprInPat sty (LazyPatIn pat)	= ppBeside (ppChar '~') (ppr sty pat)
pprInPat sty (AsPatIn name pat)
    = ppBesides [ppLparen, ppr sty name, ppChar '@', ppr sty pat, ppRparen]

pprInPat sty (ConPatIn c pats)
 = if null pats then
      ppr sty c
   else
      ppBesides [ppLparen, ppr sty c, ppSP, interppSP sty pats, ppRparen]


pprInPat sty (ConOpPatIn pat1 op pat2)
 = ppBesides [ppLparen, ppr sty pat1, ppSP, ppr sty op, ppSP, ppr sty pat2, ppRparen]

	-- ToDo: use pprOp to print op (but this involves fiddling various
	-- contexts & I'm lazy...); *PatIns are *rarely* printed anyway... (WDP)

pprInPat sty (NegPatIn pat)
  = let
	pp_pat = pprInPat sty pat
    in
    ppBeside (ppChar '-') (
    case pat of
      LitPatIn _ -> pp_pat
      _          -> ppParens pp_pat
    )

pprInPat sty (ParPatIn pat)
  = ppParens (pprInPat sty pat)

pprInPat sty (ListPatIn pats)
  = ppBesides [ppLbrack, interpp'SP sty pats, ppRbrack]
pprInPat sty (TuplePatIn pats)
  = ppBesides [ppLparen, interpp'SP sty pats, ppRparen]

pprInPat sty (RecPatIn con rpats)
  = ppBesides [ppr sty con, ppSP, ppChar '{', ppInterleave ppComma (map pp_rpat rpats), ppChar '}']
  where
    pp_rpat (v, _, True{-pun-}) = ppr sty v
    pp_rpat (v, p, _) = ppCat [ppr sty v, ppStr "<-", ppr sty p]
\end{code}

\begin{code}
instance (Eq tyvar, Outputable tyvar, Eq uvar, Outputable uvar,
	  NamedThing id, Outputable id)
       => Outputable (OutPat tyvar uvar id) where
    ppr = pprOutPat
\end{code}

\begin{code}
pprOutPat sty (WildPat ty)	= ppChar '_'
pprOutPat sty (VarPat var)	= pprNonOp sty var
pprOutPat sty (LazyPat pat)	= ppBesides [ppChar '~', ppr sty pat]
pprOutPat sty (AsPat name pat)
  = ppBesides [ppLparen, ppr sty name, ppChar '@', ppr sty pat, ppRparen]

pprOutPat sty (ConPat name ty [])
  = ppBeside (ppr sty name)
	(ifPprShowAll sty (pprConPatTy sty ty))

pprOutPat sty (ConPat name ty pats)
  = ppBesides [ppLparen, ppr sty name, ppSP,
    	 interppSP sty pats, ppRparen,
    	 ifPprShowAll sty (pprConPatTy sty ty) ]

pprOutPat sty (ConOpPat pat1 op pat2 ty)
  = ppBesides [ppLparen, ppr sty pat1, ppSP, pprOp sty op, ppSP, ppr sty pat2, ppRparen]

pprOutPat sty (ListPat ty pats)
  = ppBesides [ppLbrack, interpp'SP sty pats, ppRbrack]
pprOutPat sty (TuplePat pats)
  = ppBesides [ppLparen, interpp'SP sty pats, ppRparen]

pprOutPat sty (RecPat con ty rpats)
  = ppBesides [ppr sty con, ppChar '{', ppInterleave ppComma (map pp_rpat rpats), ppChar '}']
  where
--  pp_rpat (v, _, True{-pun-}) = ppr sty v
    pp_rpat (v, p, _) = ppBesides [ppr sty v, ppStr "<-", ppr sty p]

pprOutPat sty (LitPat l ty) 	= ppr sty l	-- ToDo: print more
pprOutPat sty (NPat   l ty e)	= ppr sty l	-- ToDo: print more

pprOutPat sty (DictPat dicts methods)
 = ppSep [ppBesides [ppLparen, ppPStr SLIT("{-dict-}")],
	  ppBracket (interpp'SP sty dicts),
	  ppBesides [ppBracket (interpp'SP sty methods), ppRparen]]

pprConPatTy sty ty
 = ppParens (ppr sty ty)
\end{code}

%************************************************************************
%*									*
%* predicates for checking things about pattern-lists in EquationInfo	*
%*									*
%************************************************************************
\subsection[Pat-list-predicates]{Look for interesting things in patterns}

Unlike in the Wadler chapter, where patterns are either ``variables''
or ``constructors,'' here we distinguish between:
\begin{description}
\item[unfailable:]
Patterns that cannot fail to match: variables, wildcards, and lazy
patterns.

These are the irrefutable patterns; the two other categories
are refutable patterns.

\item[constructor:]
A non-literal constructor pattern (see next category).

\item[literal patterns:]
At least the numeric ones may be overloaded.
\end{description}

A pattern is in {\em exactly one} of the above three categories; `as'
patterns are treated specially, of course.

\begin{code}
unfailablePats :: [OutPat a b c] -> Bool
unfailablePats pat_list = all unfailablePat pat_list

unfailablePat (AsPat	_ pat)	= unfailablePat pat
unfailablePat (WildPat	_)	= True
unfailablePat (VarPat	_)	= True
unfailablePat (LazyPat	_)	= True
unfailablePat (DictPat ds ms)	= (length ds + length ms) <= 1
unfailablePat other		= False

patsAreAllCons :: [OutPat a b c] -> Bool
patsAreAllCons pat_list = all isConPat pat_list

isConPat (AsPat _ pat)		= isConPat pat
isConPat (ConPat _ _ _)		= True
isConPat (ConOpPat _ _ _ _)	= True
isConPat (ListPat _ _)		= True
isConPat (TuplePat _)		= True
isConPat (DictPat ds ms)	= (length ds + length ms) > 1
isConPat other			= False

patsAreAllLits :: [OutPat a b c] -> Bool
patsAreAllLits pat_list = all isLitPat pat_list

isLitPat (AsPat _ pat)	= isLitPat pat
isLitPat (LitPat _ _)	= True
isLitPat (NPat   _ _ _)	= True
isLitPat other		= False
\end{code}

A pattern is irrefutable if a match on it cannot fail
(at any depth).
\begin{code}
irrefutablePat :: OutPat a b c -> Bool

irrefutablePat (WildPat _) 		  = True
irrefutablePat (VarPat _)  		  = True
irrefutablePat (LazyPat	_) 		  = True
irrefutablePat (AsPat _ pat)		  = irrefutablePat pat
irrefutablePat (ConPat con tys pats)	  = all irrefutablePat pats && only_con con
irrefutablePat (ConOpPat pat1 con pat2 _) = irrefutablePat pat1 && irrefutablePat pat1 && only_con con
irrefutablePat (ListPat _ _)		  = False
irrefutablePat (TuplePat pats)		  = all irrefutablePat pats
irrefutablePat (DictPat _ _)		  = True
irrefutablePat other_pat		  = False   -- Literals, NPat

only_con con = maybeToBool (maybeTyConSingleCon tycon)
 	       where
		 (_,_,_,tycon) = dataConSig con
\end{code}

This function @collectPatBinders@ works with the ``collectBinders''
functions for @HsBinds@, etc.  The order in which the binders are
collected is important; see @HsBinds.lhs@.
\begin{code}
collectPatBinders :: InPat a -> [a]

collectPatBinders (VarPatIn var)     = [var]
collectPatBinders (LazyPatIn pat)    = collectPatBinders pat
collectPatBinders (AsPatIn a pat)    = a : collectPatBinders pat
collectPatBinders (ConPatIn c pats)  = concat (map collectPatBinders pats)
collectPatBinders (ConOpPatIn p1 c p2)= collectPatBinders p1 ++ collectPatBinders p2
collectPatBinders (NegPatIn  pat)    = collectPatBinders pat
collectPatBinders (ParPatIn  pat)    = collectPatBinders pat
collectPatBinders (ListPatIn pats)   = concat (map collectPatBinders pats)
collectPatBinders (TuplePatIn pats)  = concat (map collectPatBinders pats)
collectPatBinders any_other_pat	     = [ {-no binders-} ]
\end{code}
