{-# LANGUAGE DataKinds, KindSignatures, OverloadedStrings, EmptyDataDecls, MultiParamTypeClasses, FlexibleContexts, OverlappingInstances   #-}

module MarXup.Diagrams where

import MarXup.MetaPost
import MarXup.Tex
import MarXup.MultiRef (Label,Multi(Raw))
import Data.Monoid
import Control.Applicative
import Data.List (intersperse)
import Data.Char (ord,chr)
import Numeric (showIntAtBase)

data Anchor = Center | N | NW | W | SW | S | SE | E | NE | Baseline | BaselineC | BaselineE
  deriving Show

allAnchors = Cons Center (Cons N (Cons NW(Cons W(Cons S
            (Cons SW(Cons SE(Cons E(Cons NE(Cons Baseline(Cons BaselineC(Cons BaselineE Nil)))))))))))

{-
           
data Anchor' :: Anchor -> * where
  Center' :: Anchor' Center
  Baseline' :: Anchor' Baseline
  NW' :: Anchor' NW
  N' :: Anchor' N
  NE' :: Anchor' NE
  E' :: Anchor' E 
  SE' :: Anchor' SE
  S' :: Anchor' S 
  SW' :: Anchor' SW
  W' :: Anchor' W
  BaselineE' :: Anchor' BaselineE
  BaselineC' :: Anchor' BaselineC
  
forget :: Anchor' a -> Anchor  
forget Center' = Center
forget Baseline' = Baseline
forget NW' = NW
forget N'  = N
forget NE' = NE
forget E'  = E 
forget SE' = SE
forget S'  = S 
forget SW' = SW
forget W'  = W
forget BaselineE' =  BaselineE
forget BaselineC' =  BaselineC
          -}
type D a = MP a
data ObjectRef -- (anchors :: List Anchor)
data Equation

unknown :: Expr Numeric -> Expr Bool
unknown (Expr x) = Expr $ "unknown " <> x

if_ :: Expr Bool -> MP () -> MP ()
if_ cond bod = "if " <> out cond <> ":" <> bod <> "fi;\n"

corner :: --Elem anchor (Cons NW (Cons NE (Cons SE (Cons SW Nil)))) => Anchor' anchor -> 
          Anchor -> Expr Picture -> Expr Pair
corner NW (Expr p) = Expr $ "ulcorner " <> p 
corner SW (Expr p) = Expr $ "llcorner " <> p 
corner NE (Expr p) = Expr $ "urcorner " <> p 
corner SE (Expr p) = Expr $ "lrcorner " <> p 
   
textObj :: TeX -> D (Expr ObjectRef)
-- (ObjectRef (Cons Center (Cons N (Cons NW(Cons W(Cons S(Cons SW(Cons SE(Cons E(Cons NE(Cons Baseline(Cons BaselineC(Cons BaselineE Nil))))))))))))))
textObj t = do
  l0 <- mpLabel
  let l = objectRef "p" l0
      p = Expr $ "q" <> encode l0
  "picture " <> out p <> ";\n" 
  out p <> " := " <> mpTex t <> ";\n"
  "pair " <> sequence_ (intersperse ", " $ [out (l <> "." <> Expr (show a)) | a <- toList allAnchors]) <> ";\n"
  
  NW ▸ l  =-= NE ▸ l
  SW ▸ l  =-= SE ▸ l
  NE ▸ l  =|= SE ▸ l
  NE ▸ l  =|= BaselineE ▸ l

  center [NW ▸ l, NE ▸ l] === N ▸ l
  center [SW ▸ l, SE ▸ l] === S ▸ l
  center [SW ▸ l, NW ▸ l] === W ▸ l
  center [SE ▸ l, NE ▸ l] === E ▸ l
  center [SW  ▸ l, NE ▸ l] === Center ▸ l
  center [Baseline ▸ l, BaselineE ▸ l] === BaselineC ▸ l
  
  NW ▸ l === Baseline ▸ l + (0 +: ypart (NW `corner` p))
  SW ▸ l === Baseline ▸ l - (0 +: ypart (SW `corner` p))
  BaselineE ▸ l === Baseline ▸ l + (xpart  (NE `corner` p) +: 0)
  
  if_ (unknown (xpart (Baseline ▸ l))) (xpart (Baseline ▸ l) === 0)
  if_ (unknown (ypart (Baseline ▸ l))) (ypart (Baseline ▸ l) === 0)

  "draw " <> out p <> " shifted " <> out (Baseline ▸ l) <> ";\n"
  "draw " <> out (Center ▸ l) <> ";\n"
  return $ l
  
infix 8 ▸ 
(▸) :: -- Elem a anchors => Anchor' a -> 
       Anchor -> 
       Expr (ObjectRef) -> Expr Pair
a ▸ (Expr x) = Expr $ x <> "." <> show a

objectRef :: String -> Label -> Expr ObjectRef -- (ObjectRef anchors)
objectRef prefix lab = Expr (prefix ++ encode lab)

encode :: Label -> String
encode n = showIntAtBase 16 (\x -> chr (ord 'a' + x)) n []

data List a = Nil | Cons a (List a)
  
toList Nil = []                    
toList (Cons x xs) =  x : (toList xs)

class Elem (a :: Anchor) (as :: List Anchor) where

instance Elem a (Cons a as) 
instance Elem a as => Elem a (Cons b as) 
