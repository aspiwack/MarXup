{-# LANGUAGE DisambiguateRecordFields, NamedFieldPuns, RecordWildCards, PostfixOperators, LiberalTypeSynonyms, TypeOperators, OverloadedStrings, PackageImports #-}

module MarXup.DerivationTrees (
-- * Basics
module Data.Monoid,
module Data.LabeledTree,

-- * Derivation' building
-- axiom, rule, etc, aborted, 
emptyDrv, haltDrv, haltDrv', delayPre,
dummy, rule, Derivation, Premise, Rule(..), 

-- * Links
LineStyle,defaultLink,Link(..),

-- * Figure building
Figure(..),

-- * Engine
derivationTree, derivationTreeD

) where

-- import DerivationTrees.Basics
import Data.List
import Data.Traversable hiding (mapM)
import "mtl" Control.Monad.Writer 
import Control.Applicative 
import Data.LabeledTree
import Data.Monoid
import MarXup (element)
import MarXup.Tex hiding (label)
import MarXup.MultiRef
import MarXup.Diagram
import MarXup.Tikz as D
import qualified Data.Tree as T
------------------
--- Basics

type LineStyle = PathOptions -> PathOptions

data Link = Link {label :: Tex (), linkStyle :: LineStyle, steps :: Int}  -- ^ Regular link
          | Detached {label :: Tex ()}   -- ^ Detach the derivation as another figure
          | Delayed -- ^ automatic delaying

defaultLink :: Link
defaultLink = Link mempty (denselyDotted . outline "black")  0


-------------------

data Rule tag = Rule {tag :: tag, ruleStyle :: LineStyle, delimiter :: Tex (), ruleLabel :: Tex (), conclusion :: Tex ()}
--  deriving Show

type Premise = Premise' ()
type Premise' a = Link ::> Derivation' a
type Derivation' tag = Tree Link (Rule tag)
type Derivation = Derivation' ()

data Figure tag = Figure {figureTag :: Label, contents :: Derivation' tag}

------------------------------------------------------------
-- Phase 1: Detach (currently disabled)

type Detach x = x -> WriterT [Figure ()] Tex x

detachP :: Detach Premise
detachP (Detached{..} ::> d) = do
  d'@(Node r ps) <- detachD d
  figureTag <- lift $ Tex $ newLabel
  tell [Figure {contents = Node r {delimiter = label} ps,..}]
  return $ (defaultLink ::> haltDrv label d)
detachP (l ::> d) = (l ::>) <$> detachD d

detachD :: Detach Derivation
detachD (Node n ps) = Node n <$> for ps detachP

detachF :: Figure () -> WriterT [Figure ()] Tex ()
detachF Figure{..} = do
  contents <- detachD contents
  tell [Figure{..}]

-- | Detach figures which should be detached.
detachTop :: [Figure ()] -> Tex [Figure ()]
detachTop fs = do 
  figs <- runWriterT $ for fs detachF
  return $ snd $ figs

--------------------------------------------------
-- Phase 2: Delay

depth (Detached{} ::> _) = 2
depth (Link{steps} ::> Node _ ps) = 1 + steps + maximum (0 : map depth ps)

isDelayed :: Premise -> Bool
isDelayed (Delayed{} ::> _) = True
isDelayed _ = False

delayPre s (Link {..} ::> j) = Link {steps = s, ..} ::> j

delayD :: Derivation -> Derivation
delayD (Node r ps0) = Node r (map delayP ps)
    where ps = fmap (fmap delayD) ps0
          ps' = filter (not . isDelayed) ps
          delayP (Delayed{..} ::> d) = defaultLink {steps = 1 + maximum (0 : map depth ps')} ::> d
          delayP p = p

delayF :: Figure () -> Figure ()
delayF (Figure{..}) = Figure{contents = delayD contents,..}

delayTop = map delayF



---------------------------------------------------------
-- Phase 3: Tag

type Tag x = x () -> Tex (x Int)

tagify :: Tag Rule
tagify (Rule {..}) = do
  tag <- Tex $ newLabel
  return $ Rule {..}

tagifyFig :: Tag Figure
tagifyFig (Figure {..}) = Figure figureTag <$> traverse tagify contents

tagifyTop :: [Figure ()] -> Tex [Figure Int]
tagifyTop = mapM tagifyFig

----------------------------------------------------------
-- Phase 4': TeXify
  
-- | Render a derivation tree without using metapost drv package (links will not be rendered properly)
derivationTree :: Derivation' a -> TeX
derivationTree = stringizeTex

stringizeTex :: Derivation' a -> TeX
stringizeTex (Node Rule {..} premises) = braces $ do
  cmd0 "displaystyle" -- so that the text does not get smaller
  cmdn "frac" [mconcat $
               intersperse (cmd0 "quad")
               [ stringizeTex v | _ ::> v <- premises]
              ,conclusion]
  braces $ do cmd0 "small"
              ruleLabel

----------------------------------------------------------
-- Phase 4'': Tikzify

derivationTreeD :: Derivation -> Tex ()
derivationTreeD d = element $ derivationTreeDiag $ delayD d
  
derivationTreeDiag :: Derivation' a -> Diagram ()
derivationTreeDiag d = do
  [h] <- newVars [ContVar] -- the height of a layer in the tree.
  minimize h
  h >== 1
  tree@(T.Node (_,n,_) _) <- toDiagram h d
  forM_ (T.levels tree) $ \ls ->
    case ls of
      [] -> return ()
      (_:ls') -> forM_ (zip ls ls') $ \((_,_,l),(r,_,_)) ->
        (l + Point 10 0) `westOf` r
  let leftFringe = map head nonNilLevs
      rightFringe = map last nonNilLevs
      nonNilLevs = filter (not . null) $ T.levels tree
  [leftMost,rightMost] <- newVars [ContVar,ContVar]
  forM_ leftFringe $ \(p,_,_) ->
    leftMost <== xpart p
  forM_ rightFringe $ \(_,_,p) ->
    xpart p <== rightMost
  minimize $ 10 *- (rightMost - leftMost)
  n # Center .=. Point 0 0

toDiagPart :: Expr -> Premise' a -> Diagram (T.Tree (Point,Object,Point))
toDiagPart layerHeight (Link{..} ::> rul)
  | steps == 0 = toDiagram layerHeight rul
  | otherwise = do
    above@(T.Node (_,concl,_) _) <- toDiagram layerHeight rul
    ptObj <- vrule
    let pt = ptObj # S
    pt `eastOf` (concl # W)
    pt `westOf` (concl # E)
    xpart pt =~= xpart (concl # Center)
    let top = ypart (concl # S)
    ypart pt + (fromIntegral steps *- layerHeight) === top
    using linkStyle $ path $ polyline [ptObj # Base,Point (xpart pt) top]
    let embedPt 1 x = T.Node (concl # W,ptObj,concl # E) [x]
        embedPt n x = T.Node (pt,ptObj,pt) [embedPt (n-1) x]
    return $ embedPt steps above

-- | @chainBases distance objects@
-- - Ensures that all the objects have the same baseline.
-- - Separates the objects by the given distance
-- - Returns an object encompassing the group, with a the baseline set correctly.
chainBases :: Expr -> [Object] -> Diagram Object
chainBases _ [] = abstractBox
chainBases spacing ls = do
  grp <- abstractBox
  D.align ypart $ map (# Base) (grp:ls)
  forM_ (zip ls (tail ls)) $ \(x,y) -> (x # E + Point spacing 0) `westOf` (y # W)
  forM_ ls $ \l -> grp `fitsVerticallyIn` l
  D.align xpart [grp # W,head ls # W]
  D.align xpart [grp # E,last ls # E]
  return grp

toDiagram :: Expr -> Derivation' a -> Diagram (T.Tree (Point,Object,Point))
toDiagram layerHeight (Node Rule{..} premises) = do
  ps <- mapM (toDiagPart layerHeight) premises
  concl <- texObj (cmd0 "strut" <> conclusion)
  lab <- texObj ruleLabel
  psGrp <- chainBases 10 [p | T.Node (_,p,_) _ <- ps]
  layerHeight === height psGrp
  separ <- abstractBox
  separ # N .=. psGrp # S
  concl # N .=. separ # S
  lab # BaseW .=. separ # E + Point 3 (negate 1)
  height separ === 0
  minimize $ width separ
  psGrp `fitsHorizontallyIn` separ
  concl `fitsHorizontallyIn` separ
  alignVert [separ # Center,concl # Center]
  localPathOptions ruleStyle $ path $ polyline [separ # W,separ # E]
  return $ T.Node (separ # W, concl, lab # E) ps

-----------------------


rule ruleLabel conclusion = Rule {tag = (), delimiter = mempty, ruleStyle = outline "black", ..}

dummy :: Rule ()
dummy = (rule mempty mempty) {ruleStyle = const defaultPathOptions}
emptyDrv = Node dummy []

-- abortDrv (Node Rule {..} _) = Node Rule {ruleStyle = Waved, ..} []

-- | Used when the rest of the derivation is known.
haltDrv' :: Tex () -> Derivation -> Derivation
haltDrv' tex (Node r _) = Node r {ruleStyle = noOutline}
     [defaultLink {steps = 1, label = tex} ::> emptyDrv]

-- | More compact variant
haltDrv :: Tex () -> Derivation -> Derivation
haltDrv t (Node r _) = Node r [defaultLink ::> Node dummy {conclusion = cmd "vdots" nil >> cmd "hspace" (tex "2pt") >> t} []]

