{-# LANGUAGE PatternGuards #-}
module Language.Fixpoint.Horn.Transformations (
    poke
  , elim
  , uniq
  , solveEbs
) where

import           Language.Fixpoint.Horn.Types
import qualified Language.Fixpoint.Types      as F
import qualified Data.HashMap.Strict          as M
import           Control.Monad (void)
import           Data.String                  (IsString (..))
import qualified Data.Set                     as S
import           Control.Monad.State
import           Data.Maybe (catMaybes)
import           Language.Fixpoint.Types.Visitor as V

-- $setup
-- >>> :l src/Language/Fixpoint/Horn/Transformations.hs src/Language/Fixpoint/Horn/Parse.hs
-- >>> :m + *Language.Fixpoint.Horn.Parse
-- >>> import Language.Fixpoint.Parse
-- >>> :set -XOverloadedStrings

------------------------------------------------------------------------------
-- | solveEbs has some preconditions
-- - pi -> k -> pi strucutre. That is, there are no cycles, and while ks
-- can depend on other ks, pis cannot directly depend on other pis
-- - predicate for exists binder is `true`. This doesn't seem hard to lift,
-- but I just haven't tested it/thought too hard about what the correct
-- behavior in this case is.
solveEbs :: Query a -> IO (Query ())
------------------------------------------------------------------------------
solveEbs (Query qs vs c) = do
  -- first we poke c, split into side and noside
  let c' = pokec c
      -- This rhs Just pattern match will fail if there's not at least one
      -- eb!
  let (Just horn, Just side) = split c'
  -- This whole business depends on Stringly-typed invariant that an ebind
  -- n corresponds to a pivar πn . That's pretty shit but I can't think of
  -- a better way to do this
  let ns = fst <$> ebs c
  -- elim pivars in noside
  let (hornNoPis, sideNoPis) = elimPis ns (horn, side)
  -- elim kvars in noside ... apply them to side, somehow?
  let ks = S.toList $ boundKvars hornNoPis
  let (hornElim, sideElim) = elimKs ks (hornNoPis, sideNoPis)
        -- perform QE and throw away the other constraints
        --   (somehow this has to be done so that we don't drop quantifiers in
        --   other things, but I guess we can just keep a list of ebinds and
        --   only do QE for *those* binders)
  -- check the side conditions
  --  (hmm, don't we need to be inside IO for this?)
  checkSides (qe sideElim)
  -- return query off to solver
  pure $ Query qs (void <$> vs) (qe hornElim)
  -- pure $ Query qs (void <$> vs) (qe $ CAnd [hornElim, sideElim])

------------------------------------------------------------------------------
{- |
>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind01.smt2"
>>> F.pprint $ qCstr (poke q)
(and
 (forall ((m int) (true))
  (and
   (forall ((x1 int) (πx1 x1))
    (and
     (forall ((v int) (v == m + 1))
      (((v == x1))))
     (forall ((v int) (v == x1 + 1))
      (((v == 2 + m))))))
   (exists ((x1 int) (true))
    ((πx1 x1))))))

>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind02.smt2"
>>> F.pprint $ qCstr (poke q)
(and
 (forall ((m int) (true))
  (forall ((z int) (z == m - 1))
   (and
    (forall ((v1 int) (v1 == z + 2))
     ((k v1)))
    (and
     (forall ((x1 int) (πx1 x1))
      (and
       (forall ((v2 int) (k v2))
        (((v2 == x1))))
       (forall ((v3 int) (v3 == x1 + 1))
        (((v3 == m + 2))))))
     (exists ((x1 int) (true))
      ((πx1 x1))))))))

>>> let c = doParse' hCstrP "" "(forall ((a Int) (p a)) (exists ((b Int) (q b)) (and (($k a)) (($k b)))))"
>>> F.pprint $ pokec c
(forall ((a int) (p a))
 (and
  (forall ((b int) (πb b))
   (and
    ((k a))
    ((k b))))
  (exists ((b int) (q b))
   ((πb b)))))
-}

poke :: Query a -> Query ()
poke (Query quals vars cstr) = Query quals (map void vars ++ pivars) (pokec cstr)
  where pivars = (\(x,t) -> HVar (piSym x) [t] ()) <$> ebs cstr

ebs :: Cstr a -> [(F.Symbol, F.Sort)]
ebs (Head _ _) = []
ebs (CAnd cs) = ebs =<< cs
ebs (All _ c) = ebs c
ebs (Any (Bind x t _) c) = (x,t) : ebs c

pokec :: Cstr a -> Cstr ()
pokec (Head c _) = Head c ()
pokec (CAnd c) = CAnd (pokec <$> c)
pokec (All b c2) = All b $ pokec c2
pokec (Any b c2) = CAnd [All b' $ pokec c2, Any b (Head pi ())]
  -- TODO: actually use the renamer?
  where
    Bind x t _p = b
    -- TODO: deal with refined ebinds somehow. currently the rest of the
    -- machinery assumes they're in the approrpiate syntactic form
    b' = Bind x t pi -- (PAnd [p, pi])
    pi = Var (piSym x) [x]

piSym :: F.Symbol -> F.Symbol
piSym s = fromString $ "π" ++ F.symbolString s

------------------------------------------------------------------------------
-- Now split the poked constraint into the side conditions and the meat of
-- the constraint

{-|
>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind01.smt2"
>>> F.pprint $ qCstr q
(and
 (forall ((m int) (true))
  (exists ((x1 int) (true))
   (and
    (forall ((v int) (v == m + 1))
     (((v == x1))))
    (forall ((v int) (v == x1 + 1))
     (((v == 2 + m))))))))

>>> let (Just noside, Just side) = split $ pokec $ qCstr q
>>> F.pprint side
(forall ((m int) (true))
 (exists ((x1 int) (true))
  ((πx1 x1))))
>>> F.pprint noside
(forall ((m int) (true))
 (forall ((x1 int) (πx1 x1))
  (and
   (forall ((v int) (v == m + 1))
    (((v == x1))))
   (forall ((v int) (v == x1 + 1))
    (((v == 2 + m)))))))


>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind02.smt2"
>>> F.pprint $ qCstr q
(and
 (forall ((m int) (true))
  (forall ((z int) (z == m - 1))
   (and
    (forall ((v1 int) (v1 == z + 2))
     ((k v1)))
    (exists ((x1 int) (true))
     (and
      (forall ((v2 int) (k v2))
       (((v2 == x1))))
      (forall ((v3 int) (v3 == x1 + 1))
       (((v3 == m + 2))))))))))

>>> let (Just noside, Just side) = split $ pokec $ qCstr q
>>> F.pprint side
(forall ((m int) (true))
 (forall ((z int) (z == m - 1))
  (exists ((x1 int) (true))
   ((πx1 x1)))))
>>> F.pprint noside
(forall ((m int) (true))
 (forall ((z int) (z == m - 1))
  (and
   (forall ((v1 int) (v1 == z + 2))
    ((k v1)))
   (forall ((x1 int) (πx1 x1))
    (and
     (forall ((v2 int) (k v2))
      (((v2 == x1))))
     (forall ((v3 int) (v3 == x1 + 1))
      (((v3 == m + 2)))))))))
-}

split :: Cstr a -> (Maybe (Cstr a), Maybe (Cstr a))
split (CAnd cs) = (andMaybes nosides, andMaybes sides)
  where (nosides, sides) = unzip $ split <$> cs
split (All b c) = (All b <$> c', All b <$> c'')
    where (c',c'') = split c
split c@Any{} = (Nothing, Just c)
split c@Head{} = (Just c, Nothing)

andMaybes cs = case catMaybes cs of
                 [] -> Nothing
                 [c] -> Just c
                 cs -> Just $ CAnd cs
------------------------------------------------------------------------------
{- |
>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind01.smt2"
>>> let (Just noside, Just side) = split $ pokec $ qCstr q
>>> F.pprint $ elimPis ["x1"] (noside, side )
(forall ((m int) (true))
 (forall ((x1 int) (forall [v : int]
  . v == m + 1 => v == x1
&& forall [v : int]
     . v == x1 + 1 => v == 2 + m))
  (and
   (forall ((v int) (v == m + 1))
    (((v == x1))))
   (forall ((v int) (v == x1 + 1))
    (((v == 2 + m))))))) : (forall ((m int) (true))
                            (exists ((x1 int) (true))
                             ((forall [v : int]
                                 . v == m + 1 => v == x1
                               && forall [v : int]
                                    . v == x1 + 1 => v == 2 + m))))

>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind02.smt2"
>>> let (Just noside, Just side) = split $ pokec $ qCstr q
>>> F.pprint $ elimPis ["x1"] (noside, side )
(forall ((m int) (true))
 (forall ((z int) (z == m - 1))
  (and
   (forall ((v1 int) (v1 == z + 2))
    ((k v1)))
   (forall ((x1 int) (forall [v2 : int]
  . $k[fix$36$$954$arg$36$k$35$1:=v2] => v2 == x1
&& forall [v3 : int]
     . v3 == x1 + 1 => v3 == m + 2))
    (and
     (forall ((v2 int) (k v2))
      (((v2 == x1))))
     (forall ((v3 int) (v3 == x1 + 1))
      (((v3 == m + 2))))))))) : (forall ((m int) (true))
                                 (forall ((z int) (z == m - 1))
                                  (exists ((x1 int) (true))
                                   ((forall [v2 : int]
                                       . $k[fix$36$$954$arg$36$k$35$1:=v2] => v2 == x1
                                     && forall [v3 : int]
                                          . v3 == x1 + 1 => v3 == m + 2)))))

-}

elimPis :: [F.Symbol] -> (Cstr a, Cstr a) -> (Cstr a, Cstr a)
elimPis [] cc = cc
elimPis (n:ns) (horn, side) = elimPis ns (applyPi n nSol horn, applyPi n nSol side)
-- TODO: handle this error?
  where Just nSol = defs n horn

-- TODO: PAnd may be a problem
applyPi :: F.Symbol -> Cstr a -> Cstr a -> Cstr a
applyPi k defs (All (Bind x t (Var k' xs)) c)
  | piSym k == k' && [k] == xs
  = All (Bind x t (Reft $ cstrToExpr defs)) c
applyPi k bp (CAnd cs)
  = CAnd $ applyPi k bp <$> cs
applyPi k bp (All b c)
  = All b (applyPi k bp c)
applyPi k bp (Any b c)
  = Any b (applyPi k bp c)
applyPi k defs (Head (Var k' xs) a)
  | piSym k == k' && [k] == xs
  -- what happens when pi's appear inside the defs for other pis?
  -- this shouldn't happen because there should be a strict
  --  pi -> k -> pi structure
  -- but that comes from the typing rules, not this format.
  = Head (Reft $ cstrToExpr defs) a
applyPi _ _ (Head p a) = Head p a

-- | The defining constraints for a pivar
--
-- The defining constraints are those that bound the value of pi_x.
--
-- We're looking to lower-bound the greatest solution to pi_x.
-- If we eliminate pivars before we eliminate kvars (and then apply the kvar
-- solutions to the side conditions to solve out the pis), then we know
-- that the only constraints that mention pi in the noside case are those
-- under the corresponding pivar binder. A greatest solution for this pivar
-- can be obtained as the _weakest precondition_ of the constraints under
-- the binder
--
-- The greatest Pi that implies the constraint under it is simply that
-- constraint itself. We can leave off constraints that don't mention n,
-- see https://photos.app.goo.gl/6TorPprC3GpzV8PL7
--
-- Actually, we can really just throw away any constraints we can't QE,
-- can't we?

{- |
>>> :{
let c = doParse' hCstrP "" "\
\(forall ((m int) (true))                  \
\ (forall ((x1 int) (and (true) (πx1 x1))) \
\  (and                                    \
\   (forall ((v int) (v == m + 1))         \
\    (((v == x1))))                        \
\   (forall ((v int) (v == x1 + 1))        \
\    (((v == 2 + m)))))))"
:}

>>> F.pprint $ defs "x1" c
Just (and
      (forall ((v int) (v == m + 1))
       ((v == x1)))
      (forall ((v int) (v == x1 + 1))
       ((v == 2 + m))))

>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind02.smt2"
>>> let (Just noside, _) = split $ pokec $ qCstr q
>>> F.pprint $ defs "x1" noside
Just (and
      (forall ((v2 int) (k v2))
       ((v2 == x1)))
      (forall ((v3 int) (v3 == x1 + 1))
       ((v3 == m + 2))))

-}

defs :: F.Symbol -> Cstr a -> Maybe (Cstr a)
defs x (CAnd cs) = andMaybes $ defs x <$> cs
defs x (All (Bind x' _ _) c)
  | x' == x
--  , (Found, c') <- filterCstr x c
  = pure c
-- defs x (All (Bind _ _ (Var k' _)) c)
--   | k' == piSym x
--   , (NotFound, _) <- filterCstr x c
--   = Nothing
defs x (All _ c) = defs x c
defs _ (Head _ _) = Nothing
defs _ (Any _ _) =  error "defs should be run only after noside and poke"

{-
-- | `filterCstr x` operates over a constraint
-- ```
-- c =
--   /\ z:t . z > 0 -> y:t . true -> z=y     (1)
--   /\ b:t . p b   -> n:t . true -> x=b     (2)
--   /\ c:t . c = x -> m:t . true -> true    (3)
-- ```
-- and should return (2) /\ (3) since they're the constraints that mention
-- `x`
filterCstr :: F.Symbol -> Cstr a -> (Found, Cstr a)
filterCstr x c@(Head p _) = (findPred x p, c)
filterCstr x (CAnd cs) = case map snd $ filter (foundToBool . fst) $ filterCstr x <$> cs of
  [] -> (NotFound, CAnd cs)
  cs' -> (Found, CAnd cs')
filterCstr x (All (Bind x' t p) c) = (f <> findPred x p, All (Bind x' t p) c')
    where
    (f, c') = filterCstr x c
filterCstr _ Any{} = error "filtercstr should only be run in the noside case of poke"

findPred:: F.Symbol -> Pred -> Found
findPred x (Reft e) = V.fold (V.Visitor const (const id) (const (eVar x))) () mempty e
findPred x (Var _ ks) = boolToFound $ elem x ks
findPred x (PAnd p) = mconcat $ findPred x <$> p

eVar x (F.EVar x') = boolToFound (x == x')
eVar _ _ = boolToFound False
-}

-- the WP we get for the defining constraints for a pivar are the wrong
-- kind of quantifier, so we need to make them expressions before we run QE
-- (or should we augment the pred type with quantifiers?
cstrToExpr :: Cstr a -> F.Expr
cstrToExpr (Head p _) = predToExpr p
cstrToExpr (CAnd cs) = F.PAnd $ cstrToExpr <$> cs
cstrToExpr (All (Bind x t p) c) = F.PAll [(x,t)] $ F.PImp (predToExpr p) $ cstrToExpr c
cstrToExpr (Any (Bind x t p) c) = F.PExist [(x,t)] $ F.PImp (predToExpr p) $ cstrToExpr c

predToExpr :: Pred -> F.Expr
predToExpr (Reft e) = e
predToExpr (Var k xs) = F.PKVar (F.KV k) (F.Su $ M.fromList su)
  where su = zip (kargs k) (F.EVar <$> xs)
predToExpr (PAnd ps) = F.PAnd $ predToExpr <$> ps

------------------------------------------------------------------------------
-- let's take a stab at this, shall, we?
{- |
>>> (q, opts) <- parseFromFile hornP "tests/horn/pos/ebind02.smt2"
>>> let (Just noside, Just side) = split $ pokec $ qCstr q
>>> F.pprint $ elimKs ["k"] $ elimPis ["x1"] (noside, side)
(forall ((m int) (true))
 (forall ((z int) (z == m - 1))
  (and
   (forall ((v1 int) (v1 == z + 2))
    ((true)))
   (forall ((x1 int) (forall [v2 : int]
  . exists [v1 : int]
      . (v2 == v1)
        && v1 == z + 2 => v2 == x1
&& forall [v3 : int]
     . v3 == x1 + 1 => v3 == m + 2))
    (and
     (forall ((v1 int) (v1 == z + 2))
      (forall ((v2 int) (v2 == v1))
       (((v2 == x1)))))
     (forall ((v3 int) (v3 == x1 + 1))
      (((v3 == m + 2))))))))) : (forall ((m int) (true))
                                 (forall ((z int) (z == m - 1))
                                  (exists ((x1 int) (true))
                                   ((forall [v2 : int]
                                       . exists [v1 : int]
                                           . (v2 == v1)
                                             && v1 == z + 2 => v2 == x1
                                     && forall [v3 : int]
                                          . v3 == x1 + 1 => v3 == m + 2)))))
-}
elimKs :: [F.Symbol] -> (Cstr a, Cstr a) -> (Cstr a, Cstr a)
elimKs [] cc = cc
elimKs (k:ks) (horn, side) = elimKs ks (horn', side')
  where sol = sol1 k (scope k horn)
        -- Eliminate Kvars inside Cstr inside horn, and in Expr (under
        -- quantifiers waiting to be eliminated) in both.
        horn' = doelim' k sol . doelim k sol $ horn
        side' = doelim' k sol side

doelim' k bss (CAnd cs) = CAnd $ doelim' k bss <$> cs
doelim' k bss (Head p a) = Head (tx k bss p) a
doelim' k bss (All (Bind x t p) c) = All (Bind x t $ tx k bss p) (doelim' k bss c)
doelim' k bss (Any (Bind x t p) c) = Any (Bind x t $ tx k bss p) (doelim' k bss c)

-- [NOTE-elimK-positivity]:
--
-- uh-oh I suspect this traversal is WRONG. We can build an
-- existentialPackage as a solution to a K in a negative position, but in
-- the *positive* position, the K should be solved to FALSE.
--
-- Well, this may be fine --- semantically, this is all the same, but the
-- exists in the positive positions (which will stay exists when we go to
-- prenex) may give us a lot of trouble during _quantifier elimination_
tx :: F.Symbol -> [[Bind]] -> Pred -> Pred
tx k bss = V.mapKVars' existentialPackage
  where
  splitBinds xs = unzip $ (\(Bind x t p) -> ((x,t),p)) <$> xs
  cubeSol su (Bind _ _ (Reft eqs):xs)
    | (xts, es) <- splitBinds xs
    = F.PExist xts $ F.PAnd  (F.subst su eqs : map predToExpr es)
  cubeSol _ _ = error "cubeSol in doelim'"
  existentialPackage (F.KV k', su) | k' == k = Just $ F.PAnd $ cubeSol su . reverse <$> bss
  existentialPackage _ = Nothing

-- Visitor only visit Exprs in Pred!
instance V.Visitable Pred where
  visit v c (PAnd ps) = PAnd <$> mapM (visit v c) ps
  visit v c (Reft e) = Reft <$> visit v c e
  visit _ _ var      = pure var

------------------------------------------------------------------------------
-- | Quantifier elimination for use with implicit solver
qe :: Cstr a -> Cstr a
------------------------------------------------------------------------------
-- Initially this QE seemed straightforward, and does seem so in the body:
--
--    \-/ v . v = t -> r
--    ------------------
--          r[t/v]
--
-- And this works. However, the mixed quantifiers get pretty bad in the
-- side condition, which generally looks like
--    forall a1 ... an . exists n . forall v1 . ( exists karg . p ) => q
--
-- OR is it
--    forall a1 ... an . exists n . forall v1 . ( exists karg . p ) => (exists karg' . q)
-- see [NOTE-elimK-positivity]?

qe = V.mapExpr forallEqElim

-- Need to do some massaging to actually get into this form...
forallEqElim (F.PAll [(x,_)] (F.PImp (F.PAtom F.Eq a b) e))
  | F.EVar x' <- a
  , x == x'
  = F.subst1 e (x,b)
  | F.EVar x' <- b
  , x == x'
  = F.subst1 e (x,a)
forallEqElim e = e

instance V.Visitable (Cstr a) where
  visit v c (CAnd cs) = CAnd <$> mapM (visit v c) cs
  visit v c (Head p a) = Head <$> visit v c p <*> pure a
  visit v ctx (All (Bind x t p) c) = All <$> (Bind x t <$> visit v ctx p) <*> visit v ctx c
  visit v ctx (Any (Bind x t p) c) = All <$> (Bind x t <$> visit v ctx p) <*> visit v ctx c

------------------------------------------------------------------------------
checkSides :: Cstr a -> IO ()
checkSides _side = pure ()

------------------------------------------------------------------------------
-- | uniq makes sure each binder has a unique name
------------------------------------------------------------------------------
type RenameMap = M.HashMap F.Symbol Integer

uniq :: Cstr a -> Cstr a
uniq c = evalState (uniq' c) M.empty

uniq' :: Cstr a -> State RenameMap (Cstr a)
uniq' (Head c a) = Head <$> gets (rename c) <*> pure a
uniq' (CAnd c) = CAnd <$> mapM uniq' c
uniq' (All b c2) = do
    b' <- uBind b
    All b' <$> uniq' c2
uniq' (Any b c2) = do
    b' <- uBind b
    Any b' <$> uniq' c2

uBind :: Bind -> State RenameMap Bind
uBind (Bind x t p) = do
   x' <- uVariable x
   Bind x' t <$> gets (rename p)

uVariable :: IsString a => F.Symbol -> State RenameMap a
uVariable x = do
   i <- gets (M.lookupDefault (-1) x)
   modify (M.insert x (i+1))
   pure $ numSym x (i+1)

rename :: Pred -> RenameMap -> Pred
rename e m = substPred (M.mapWithKey numSym m) e

numSym :: IsString a => F.Symbol -> Integer -> a
numSym s 0 = fromString $ F.symbolString s
numSym s i = fromString $ F.symbolString s ++ "#" ++ show i

substPred :: M.HashMap F.Symbol F.Symbol -> Pred -> Pred
substPred su (Reft e) = Reft $ F.subst (F.Su $ F.EVar <$> su) e
substPred su (PAnd ps) = PAnd $ substPred su <$> ps
substPred su (Var k xs) = Var k $ upd <$> xs
  where upd x = M.lookupDefault x x su

------------------------------------------------------------------------------
-- | elim solves all of the KVars in a Cstr (assuming no cycles...)
-- >>> elim . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test00.smt2"
-- (and (forall ((x int) (x > 0)) (forall ((y int) (y > x)) (forall ((v int) (v == x + y)) ((v > 0))))))
-- >>> elim . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test01.smt2"
-- (and (forall ((x int) (x > 0)) (and (forall ((y int) (y > x)) (forall ((v int) (v == x + y)) ((v > 0)))) (forall ((z int) (z > 100)) (forall ((v int) (v == x + z)) ((v > 100)))))))
-- >>> elim . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test02.smt2"
-- (and (forall ((x int) (x > 0)) (and (forall ((y int) (y > x + 100)) (forall ((v int) (v == x + y)) ((true)))) (forall ((y int) (y > x + 100)) (forall ((v int) (v == x + y)) (forall ((z int) (z == v)) (forall ((v int) (v == x + z)) ((v > 100)))))))))
------------------------------------------------------------------------------
elim :: Cstr a -> Cstr a
------------------------------------------------------------------------------
elim c = if S.null $ boundKvars res then res else error "called elim on cyclic fucker"
  where
  res = S.foldl elim1 c (boundKvars c)

elim1 :: Cstr a -> F.Symbol -> Cstr a
-- Find a `sol1` solution to a kvar `k`, and then subsitute in the solution for
-- each rhs occurence of k.
elim1 c k = doelim k sol c
  where sol = sol1 k (scope k c)

-- scope drops extraneous leading binders so that we can take the strongest
-- scoped solution instead of the strongest solution
scope :: F.Symbol -> Cstr a -> Cstr a
scope k = go . snd . scope' k
  where go (All _ c') = go c'
        go c = c

-- |
-- >>> sc <- scope' "k0" . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test02.smt2"
-- >>> sc
-- (True,(forall ((x ... (and (forall ((y ... (forall ((v ... ((k0 v)))) (forall ((z ...

-- scope' prunes out branches that don't have k
scope' :: F.Symbol -> Cstr a -> (Bool, Cstr a)

scope' k (CAnd c) = case map snd $ filter fst $ map (scope' k) c of
                     []  -> (False, CAnd [])
                     [c] -> (True, c)
                     cs  -> (True, CAnd cs)

-- TODO: Bind PAnd Case
scope' k c@(All (Bind x t (Var k' su)) c')
  | k == k' = (True, c)
  | otherwise = All (Bind x t (Var k' su)) <$> scope' k c'
scope' k c@(All _ c')
  = const c <$> scope' k c'
scope' _ (Any _ _) = error "ebinds don't work with old elim"

scope' k c@(Head (Var k' _) _)
-- this case seems extraneous?
  | k == k'   = (True, c)
scope' _ c@Head{} = (False, c)

-- | A solution is a Hyp of binders (including one anonymous binder
-- that I've singled out here).
-- (What does Hyp stand for? Hypercube? but the dims don't line up...)
--
-- >>> c <- qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test02.smt2"
-- >>> sol1 ("k0") (scope "k0" c)
-- [[((y int) (y > x + 100)),((v int) (v == x + y)),((_ bool) (κarg$k0#1 == v))]]
-- >>> c <- qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test03.smt2"
-- >>> sol1 ("k0") (scope "k0" c)
-- [[((x int) (x > 0)),((v int) (v == x)),((_ bool) (κarg$k0#1 == v))],[((y int) (k0 y)),((v int) (v == y + 1)),((_ bool) (κarg$k0#1 == v))]]
-- >>> let c = doParse' hCstrP "" "(forall ((a Int) (p a)) (forall ((b Int) (q b)) (and (($k a)) (($k b)))))"
-- >>> sol1 "k" c
-- [[((a int) (p a)),((b int) (q b)),((_ bool) (κarg$k#1 == a))],[((a int) (p a)),((b int) (q b)),((_ bool) (κarg$k#1 == b))]]

-- Naming conventions:
--  - `b` is a binder `forall . x:t .p =>`
--  - `bs` is a list of binders, or a "cube" that tracks all of the
--     information on the rhs of a given constraint
--  - `bss` is a Hyp, that tells us the solution to a Var, that is,
--     a collection of cubes that we'll want to disjunct

sol1 :: F.Symbol -> Cstr a -> [[Bind]]
sol1 k (CAnd cs) = sol1 k =<< cs
sol1 k (All b c) = (b:) <$> sol1 k c
sol1 k (Head (Var k' ys) _) | k == k'
  = [[Bind (fromString "_") F.boolSort $ Reft $ F.PAnd $ zipWith (F.PAtom F.Eq) (F.EVar <$> xs) (F.EVar <$> ys)]]
  where xs = zipWith const (kargs k) ys
sol1 _ (Head _ _) = []
sol1 _ (Any _ _) =  error "ebinds don't work with old elim"

kargs k = fromString . (("κarg$" ++ F.symbolString k ++ "#") ++) . show <$> [1..]

-- |
-- >>> let c = doParse' hCstrP "" "(forall ((z Int) ($k0 z)) ((z = x)))"
-- >>> doelim "k0" [[Bind "v" F.boolSort (Reft $ F.EVar "v"), Bind "_" F.boolSort (Reft $ F.EVar "donkey")]]  c
-- (forall ((v bool) (v)) (forall ((z int) (donkey)) ((z == x))))

doelim :: F.Symbol -> [[Bind]] -> Cstr a -> Cstr a
doelim k bp (CAnd cs)
  = CAnd $ doelim k bp <$> cs
doelim k bss (All (Bind x t (Var k' xs)) c)
  | k == k'
  = mkAnd $ cubeSol . reverse <$> bss
  where su = F.Su $ M.fromList $ zip (kargs k) (F.EVar <$> xs)
        mkAnd [c] = c
        mkAnd cs = CAnd cs
        cubeSol ((Bind _ _ (Reft eqs)):xs) = foldl (flip All) (All (Bind x t (Reft $ F.subst su eqs)) $ doelim k bss c) xs
        cubeSol _ = error "internal error"
--- TODO: what about the PAnd case inside b?
doelim k bp (All b c)
  = All b (doelim k bp c)
doelim k _ (Head (Var k' _) a)
  | k == k'
  = Head (Reft F.PTrue) a
doelim _ _ (Head p a) = Head p a
doelim _ _ (Any _ _) =  error "ebinds don't work with old elim"

-- | Returns a list of KVars with their arguments that are present as
--
-- >>> boundKvars . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/ebind01.smt2"
-- ... []
-- >>> boundKvars . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/ebind02.smt2"
-- ... ["k"]
-- >>> boundKvars . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test00.smt2"
-- ... []
-- >>> boundKvars . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test01.smt2"
-- ... []
-- >>> boundKvars . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test02.smt2"
-- ... ["k0"]
-- >>> boundKvars . qCstr . fst <$> parseFromFile hornP "tests/horn/pos/test03.smt2"
-- ... ["k0"]

boundKvars :: Cstr a -> S.Set F.Symbol
boundKvars (Head p _) = pKVars p
boundKvars (CAnd c) = mconcat $ boundKvars <$> c
boundKvars (All (Bind _ _ p) c) = pKVars p <> boundKvars c
boundKvars (Any (Bind _ _ p) c) = pKVars p <> boundKvars c

pKVars (Var k _) = S.singleton k
pKVars (PAnd ps) = mconcat $ pKVars <$> ps
pKVars _ = S.empty