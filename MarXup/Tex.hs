{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies,TypeSynonymInstances,FlexibleInstances #-}

module MarXup.Tex where

import MarXup
import Control.Monad.Reader
import Control.Monad.RWS
import Control.Applicative
import GHC.Exts( IsString(..) )
import Data.List (intersperse)
import MarXup.MultiRef
import Graphics.DVI
import System.Process

data MPOutFormat = SVG | EPS
  deriving (Eq,Show)

newtype Tex a = Tex {fromTex :: Multi a}
  deriving (Monad, MonadFix, Applicative, Functor)

---------------------------------
-- MarXup interface
instance Textual Tex where
    textual s = Tex $ (Raw Normal $ concatMap escape s)

kern :: String -> TeX
kern x = braces $ tex $ "\\kern " ++ x

escape '\\' = "\\ensuremath{\\backslash{}}"
escape '~' = "\\ensuremath{\\sim{}}"
escape '<' = "\\ensuremath{<}"
escape '>' = "\\ensuremath{>}"
escape c | c `elem` "^_{}&$%" = '\\':c:[]
escape c = [c]

instance Element (Tex a) where
  type Target (Tex a) = Tex a
  element = id

texInMode ::  Mode -> String ->TeX
texInMode mode = Tex . Raw mode

tex :: String -> TeX
tex = texInMode Normal

type TeX = Tex ()

newLabel :: Tex Label
newLabel = Tex $ Label

reference :: Label -> Tex ()
reference l = Tex $ Raw Normal (show l)

instance Monoid (TeX) where
  mempty = textual ""
  mappend = (>>)

instance IsString (TeX) where
  fromString = textual

texLn :: String -> TeX
texLn s = tex s >> tex "\n"

texLines :: [String] -> Tex ()
texLines = mapM_ texLn

genParen :: String -> Tex a -> Tex a
genParen [l,r] x = tex [l] *> x <* tex [r]

braces,brackets :: Tex a -> Tex a
braces = genParen "{}"
brackets = genParen "[]"

backslash :: TeX
backslash = tex ['\\']

nil :: TeX
nil = braces (tex "")

-- | Command with no argument
cmd0 :: String -> Tex ()
cmd0 c = cmdn' c [] [] >> return ()

-- | Command with one argument
cmd :: String -> Tex a -> Tex a
cmd c = cmd' c []

-- | Command with options
cmd' :: String -> [String] -> Tex b -> Tex b
cmd' cmd options arg = do
  [x] <- cmdn' cmd options [arg]
  return x

-- | Command with options and many arguments
cmdn' :: String -> [String] -> [Tex a] -> Tex [a]
cmdn' cmd options args = do
  backslash >> tex cmd
  when (not $ null options) $ brackets $ sequence_ $ map tex $ intersperse "," options
  res <- sequence $ map braces args
  when (null args) $ tex "{}" -- so that this does not get glued with the next thing.
  return res

-- | Command with tex options and many arguments
cmdm :: String -> [Tex a] -> [Tex a] -> Tex [a]
cmdm cmd options args = do
  backslash >> tex cmd
  when (not $ null options) $ sequence_ $ map brackets $ options
  res <- sequence $ map braces args
  when (null args) $ tex "{}" -- so that this does not get glued with the next thing.
  return res


cmdn'_ :: String -> [String] -> [TeX] -> Tex ()
cmdn'_ cmd options args = cmdn' cmd options args >> return ()

-- | Command with n arguments
cmdn :: String -> [Tex a] -> Tex [a]
cmdn c args = cmdn' c [] args

cmdn_ :: String -> [TeX] -> Tex ()
cmdn_ cmd args = cmdn'_ cmd [] args

-- | Environment
env :: String -> Tex a -> Tex a
env x = env' x []

-- | Environment with options
env' :: String -> [String] -> Tex a -> Tex a
env' e opts body = env'' e opts [] body

-- | Environment with a tex option
env'' :: String -> [String] -> [TeX] -> Tex a -> Tex a
env'' e opts args body = do
  cmd "begin" $ tex e
  when (not $ null opts) $ brackets $ sequence_ $ map tex $ intersperse "," opts
  mapM_ braces args
  x <- body
  cmd "end" $ tex e
  return x

------------------
-- Sorted labels

data SortedLabel =  SortedLabel String Label

label :: String -> Tex SortedLabel
label s = do
  l <- newLabel
  cmd "label" (reference l)
  return $ SortedLabel s l

xref :: SortedLabel -> TeX
xref (SortedLabel _ l) = do
  cmd "ref" (reference l)
  return ()

fxref :: SortedLabel -> TeX
fxref l@(SortedLabel s _) = do
  textual s
  tex "~" -- non-breakable space here
  xref l

instance Element SortedLabel where
  type Target SortedLabel = TeX
  element x = fxref x >> return ()


-----------------
-- Generate boxes

outputAlsoInBoxMode :: Tex a -> Tex (a,BoxSpec)
outputAlsoInBoxMode (Tex a) = Tex $ MarXup.MultiRef.Box $ a
  
-- generateBoxes :: Tex a -> String
-- generateBoxes (Tex t) = mconcat (map inShipout bxs) 
--   where (_,_,Boxes bxs _) = runRWS (fromBoxer $ getBoxes $ runReaderT t ("<no filepath>",EPS) ) False 0

inBox :: Tex a -> Tex (a,BoxSpec)
inBox x = outputAlsoInBoxMode $ do
  texInMode BoxOnly "\\mpxshipout%\n"
  r <- x
  texInMode BoxOnly "%\n\\stopmpxshipout\n"
  return r

shipoutMacros :: TeX
shipoutMacros = texInMode BoxOnly "\
\  \\gdef\\mpxshipout{\\shipout\\hbox\\bgroup                              \n\
\    \\setbox0=\\hbox\\bgroup}                                             \n\
\  \\gdef\\stopmpxshipout{\\egroup  \\dimen0=\\ht0 \\advance\\dimen0\\dp0  \n\
\    \\dimen1=\\ht0 \\dimen2=\\dp0                                         \n\
\    \\setbox0=\\hbox\\bgroup                                              \n\
\      \\box0                                                              \n\
\      \\ifnum\\dimen0>0 \\vrule width1sp height\\dimen1 depth\\dimen2     \n\
\      \\else \\vrule width1sp height1sp depth0sp\\relax                   \n\
\      \\fi\\egroup                                                        \n\
\    \\ht0=0pt \\dp0=0pt \\box0 \\egroup}                                  \n\
\ "

tikzpackage :: TeX
tikzpackage = texInMode NotBoxOnly "\\usepackage{tikz}"

renderWithBoxes :: [BoxSpec] -> InterpretMode -> Tex a -> String
renderWithBoxes bs mode (Tex t) = doc
  where (_,_,doc) = runRWS (fromDisplayer $ display $ t) mode (0,bs)

renderTex :: (Bool -> TeX) -> TeX -> IO String
renderTex preamble body = do
  let bxsTex = renderWithBoxes (repeat nilBoxSpec) OutsideBox (wholeDoc True)
      boxesName = "mpboxes"
      wholeDoc inBoxMode = do
        outputAlsoInBoxMode (preamble inBoxMode)
        shipoutMacros
        texInMode Always "\\begin{document}"
        body
        texInMode Always "\\end{document}"
  writeFile (boxesName ++ ".tex") bxsTex
  system $ "latex " ++ boxesName
  boxes <- withDVI (boxesName ++ ".dvi") (\_ _ -> return emptyFont) () getBoxInfo
  putStrLn $ "Number of boxes found: " ++ show (length boxes)
  return $ renderWithBoxes (nilBoxSpec:boxes) Regular $ (wholeDoc False)
  -- ???? Hack???? I cannot figure out why an extra nil box is needed here.

getBoxInfo :: () -> Page -> IO (Maybe ((), BoxSpec))
getBoxInfo () (Page _ [(_,Graphics.DVI.Box objs)] _) = return (Just ((),dims))
  where ((width,descent),Rule _ height) = last objs
        dims = BoxSpec (scale width) (scale height) (negate $ scale descent)
        scale x = fromIntegral x / 65536
getBoxInfo () (Page _ objs _) = error $ "getBoxInfo oops: " ++ show objs

