{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}

-- |
-- Module      : Script to parse Unicode XML database and convert
--               it to Haskell data structures
--
-- Copyright   : (c) 2014–2015 Antonio Nikishaev
--               (c) 2016-2017 Harendra Kumar
--
-- License     : BSD-style
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
--
--
module Main where

import           Prelude hiding (pred)
import           Control.DeepSeq      (NFData (..), deepseq)
import           Control.Exception
import           Data.Binary          as Bin
import           Data.Bits            (shiftL)
import qualified Data.ByteString.Lazy as L
import           Data.Char            (chr)
import           Data.Char            (ord)
import           Data.List            (unfoldr)
import           Data.Map             ((!))
import qualified Data.Map             as M
import           Data.Monoid          ((<>))
import qualified Data.Set             as S
import           GHC.Generics         (Generic)
import           System.FilePath      ((-<.>))
import           Text.HTML.TagSoup    (Tag (..), parseTags)
import           WithCli              (withCli)

import           Data.Unicode.Properties.DecomposeHangul (isHangul)

data GeneralCategory =
    Lu|Ll|Lt|             --LC
    Lm|Lo|                --L
    Mn|Mc|Me|             --M
    Nd|Nl|No|             --N
    Pc|Pd|Ps|Pe|Pi|Pf|Po| --P
    Sm|Sc|Sk|So|          --S
    Zs|Zl|Zp|             --Z
    Cc|Cf|Cs|Co|Cn        --C
    deriving (Show, Read, Generic, NFData, Binary)

data DecompType =
       DTCanonical | DTCompat  | DTFont
     | DTNoBreak   | DTInitial | DTMedial   | DTFinal
     | DTIsolated  | DTCircle  | DTSuper    | DTSub
     | DTVertical  | DTWide    | DTNarrow
     | DTSmall     | DTSquare  | DTFraction
    deriving (Show,Eq,Generic, NFData, Binary)

data Decomp = DCSelf | DC [Char] deriving (Show,Eq,Generic, NFData, Binary)
data QCValue = QCYes | QCNo | QCMaybe deriving (Show,Generic, NFData, Binary)

data CharProps = CharProps {
      _name                       :: String,
      _generalCategory            :: GeneralCategory,
      _upper                      :: Bool,
      _lower                      :: Bool,
      _otherUpper                 :: Bool,
      _otherLower                 :: Bool,
      _nfc_qc                     :: QCValue,
      _nfd_qc                     :: Bool,
      _nfkc_qc                    :: QCValue,
      _nfkd_qc                    :: Bool,
      _combiningClass             :: Int,
      _dash                       :: Bool,
      _hyphen                     :: Bool,
      _quotationMark              :: Bool,
      _terminalPunctuation        :: Bool,
      _diactric                   :: Bool,
      _extender                   :: Bool,
      _decomposition              :: Decomp,
      _decompositionType          :: Maybe DecompType,
      _fullDecompositionExclusion :: Bool
} deriving (Show,Generic, NFData, Binary)

-------------------------------------------------------------------------------
-- Generate data structures for decompositions
-------------------------------------------------------------------------------

genSignature :: String -> String
genSignature testBit = testBit <> " :: Char -> Bool"

-- | Check that var is between minimum and maximum of orderList
genRangeCheck :: String -> [Int] -> String
genRangeCheck var ordList =
      var <> " >= "
      <> show (minimum ordList) <> " && " <> var <> " <= "
      <> show (maximum ordList)

genBitmap :: String -> [Int] -> String
genBitmap funcName ordList = unlines
  [ genSignature funcName
  , funcName <> " = \\c -> let n = ord c in " ++ genRangeCheck "n" ordList ++ " && lookupBit64 bitmap# n"
  , "  where"
  , "    bitmap# = " ++ show (bitMapToAddrLiteral (positionsToBitMap ordList)) ++ "#"
  ]

positionsToBitMap :: [Int] -> [Bool]
positionsToBitMap = go 0
  where
    go _ [] = []
    go i xxs@(x : xs)
      | i < x     = False : go (i + 1) xxs
      | otherwise = True  : go (i + 1) xs

bitMapToAddrLiteral :: [Bool] -> String
bitMapToAddrLiteral = map (chr . toByte . padTo8) . unfoldr go
  where
    go :: [a] -> Maybe ([a], [a])
    go [] = Nothing
    go xs = Just (take 8 xs, drop 8 xs)

    padTo8 :: [Bool] -> [Bool]
    padTo8 xs
      | length xs >= 8 = xs
      | otherwise = xs ++ replicate (8 - length xs) False

    toByte :: [Bool] -> Int
    toByte xs = sum $ map (\i -> if xs !! i then 1 `shiftL` i else 0) [0..7]

genCombiningClass :: PropertiesDB -> String -> String
genCombiningClass props file = unlines
            [ "-- autogenerated from Unicode data"
            , "{-# LANGUAGE MagicHash #-}"
            , "module Data.Unicode.Properties." <> file
            , "(getCombiningClass, isCombining)"
            , "where"
            , ""
            , "import Data.Char (ord)"
            , "import Data.Unicode.Internal.Bits (lookupBit64)"
            , ""
            , "getCombiningClass :: Char -> Int"
            , concat $ map genCombiningClassDef ccmap
            , "getCombiningClass _ = 0\n"
            , ""
            , "{-# INLINE isCombining #-}"
            , genBitmap "isCombining" ordList
            ]
    where
        genCombiningClassDef (c, d) =
            "getCombiningClass " <> show c <> " = " <> show d <> "\n"

        ccmap = (filter (\(_,cc) -> cc /= 0)
                 . map (\(c,prop) -> (c, _combiningClass prop))) props

        ordList = map (ord . fst) ccmap

data DType = Canonical | Kompat

decompositions :: DType -> PropertiesDB -> [(Char, [Char])]
decompositions dtype =
      map    (\(c, prop) -> (c, decomposeChar c (_decomposition prop)))
    . filter (predicate   . _decompositionType . snd)
    . filter ((/= DCSelf) . _decomposition . snd)
    where predicate = case dtype of
              Canonical -> (== Just DTCanonical)
              Kompat    -> (const True)

genDecomposable :: DType -> PropertiesDB -> String -> String
genDecomposable dtype props file = unlines
            [ "-- autogenerated from Unicode data"
            , "{-# LANGUAGE MagicHash #-}"
            , "module Data.Unicode.Properties." <> file
            , "(isDecomposable)"
            , "where"
            , ""
            , "import Data.Char (ord)"
            , "import Data.Unicode.Internal.Bits (lookupBit64)"
            , ""
            , "{-# INLINE isDecomposable #-}"
            , genBitmap "isDecomposable" ordList
            ]
    where
        chrList = filter (not . isHangul)
                         (map fst (decompositions dtype props))
        ordList = map ord chrList

decomposeChar :: Char -> Decomp -> [Char]
decomposeChar c DCSelf   = [c]
decomposeChar _c (DC ds) = ds

genDecomposeModuleHdr :: String -> String
genDecomposeModuleHdr file = unlines
    [ "{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}"
    , "-- autogenerated from Unicode data"
    , "module Data.Unicode.Properties." <> file
    , "(decomposeChar)"
    , "where"
    ]

genDecomposeSign :: String
genDecomposeSign = unlines
    [ ""
    , "-- Note: this is a partial function we do not expect to call"
    , "-- this if isDecomposable returns false."
    , "{-# NOINLINE decomposeChar #-}"
    , "decomposeChar :: Char -> [Char]"
    ]

genDecomposeDefs :: DType -> PropertiesDB -> (Int -> Bool) -> String
genDecomposeDefs dtype props pred =
    concat $ map (genDecomposeDef "decomposeChar") decomps
    where
        decomps =
              filter (pred . ord . fst)
            . filter (not . isHangul . fst)
            $ (decompositions dtype props)
        genDecomposeDef name (c, d) =
            name <> " " <> show c <> " = " <> show d <> "\n"

genDecompositions :: PropertiesDB -> String -> String
genDecompositions props file = unlines
            [ genDecomposeModuleHdr file
            , genDecomposeSign
            , genDecomposeDefs Canonical props (const True)
            ]

-- Compatibility decompositions are split in two parts to keep the file sizes
-- short enough
genDecompositionsK :: PropertiesDB -> String -> String
genDecompositionsK props file = unlines
            [ genDecomposeModuleHdr file
            , "import qualified Data.Unicode.Properties.DecompositionsK2 as DK2"
            , genDecomposeSign
            , genDecomposeDefs Kompat props (< 60000)
            , "decomposeChar c = DK2.decomposeChar c"
            ]

genDecompositionsK2 :: PropertiesDB -> String -> String
genDecompositionsK2 props file = unlines
            [ genDecomposeModuleHdr file
            , genDecomposeSign
            , genDecomposeDefs Kompat props (>= 60000)
            ]

-------------------------------------------------------------------------------
-- Generate data structures for compositions
-------------------------------------------------------------------------------

genCompositions :: PropertiesDB -> String -> String
genCompositions props file = unlines
            [ "-- autogenerated from Unicode data"
            , "{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}"
            , "{-# LANGUAGE MagicHash #-}"
            , "module Data.Unicode.Properties." <> file
            , "(composePair, composePairNonCombining, composePairSecondNonCombining)"
            , "where"
            , ""
            , "import Data.Char (ord)"
            , "import Data.Unicode.Internal.Bits (lookupBit64)"
            , ""
            , "{-# NOINLINE composePair #-}"
            , "composePair :: Char -> Char -> Maybe Char"
            , concat $ map (genComposePair "composePair") decomps
            , "composePair _ _ = " <> "Nothing" <> "\n"
            , ""
            , "composePairNonCombining :: Char -> Char -> Maybe Char"
            , concat $ map (genComposePair "composePairNonCombining") decompsNonCombining
            , "composePairNonCombining _ _ = " <> "Nothing" <> "\n"
            , ""
            , genBitmap "composePairSecondNonCombining" composePairSecondNonCombining
            ]
    where
        genComposePair name (c, [d1, d2]) =
            name <> " " <> show d1 <> " " <> show d2 <> " = Just " <> show c <> "\n"
        genComposePair _ _ = error "Bug: decomp length is not 2"

        decomps =   filter ((flip S.notMember) exclusions . fst)
                  . filter (not . isHangul . fst)
                  . filter ((== 2) . length . snd)
                  $ (decompositions Canonical props)

        exclusions =  S.fromList
                    . map fst
                    . filter (_fullDecompositionExclusion . snd) $ props

        composePairSecond = S.fromList $ map (ord . head . tail . snd) decomps
        combiningChars = S.fromList $ map (ord . fst) $ filter ((/= 0) . _combiningClass . snd) props
        composePairSecondNonCombining = S.toList $ composePairSecond S.\\ combiningChars

        decompsNonCombining = filter ((`S.notMember` combiningChars) . ord . head . tail . snd) decomps

-------------------------------------------------------------------------------
-- Create and read binary properties data
-------------------------------------------------------------------------------

readSavedProps :: FilePath -> IO [(Char, CharProps)]
readSavedProps file = Bin.decode <$> L.readFile file

writeBinary :: Binary a => FilePath -> a -> IO ()
writeBinary file props = do
  L.writeFile file (Bin.encode props)

type PropertiesDB = [(Char,CharProps)]

readQCValue :: String -> QCValue
readQCValue "Y" = QCYes
readQCValue "N" = QCNo
readQCValue "M" = QCMaybe
readQCValue x = error $ "Unknown QCValue: " ++ show x

readYN :: String -> Bool
readYN "Y" = True
readYN "N" = False
readYN x = error $ "Unknown YNValue: " ++ show x

readCodePoint :: String -> Char
readCodePoint = chr . read . ("0x"++)

readDecomp :: String -> Decomp
readDecomp "#" = DCSelf
readDecomp s   = DC . map readCodePoint $ words s

readDecompType :: String -> Maybe DecompType
readDecompType "none" = Nothing
readDecompType s      = Just (dtmap!s)
    where
        dtmap = M.fromList
            [
              ("can"       , DTCanonical)
            , ("com"       , DTCompat   )
            , ("enc"       , DTCircle   )
            , ("fin"       , DTFinal    )
            , ("font"      , DTFont     )
            , ("fra"       , DTFraction )
            , ("init"      , DTInitial  )
            , ("iso"       , DTIsolated )
            , ("med"       , DTMedial   )
            , ("nar"       , DTNarrow   )
            , ("nb"        , DTNoBreak  )
            , ("sml"       , DTSmall    )
            , ("sqr"       , DTSquare   )
            , ("sub"       , DTSub      )
            , ("sup"       , DTSuper    )
            , ("vert"      , DTVertical )
            , ("wide"      , DTWide     )
            ]

toProp :: Tag String -> PropertiesDB
toProp (TagOpen _ psml) = [ (c, CharProps{..}) | c <- cps ]
    where
        psm = M.fromList psml
        cps = let readCP = (fmap readCodePoint . (`M.lookup` psm))
              in case readCP <$> ["cp", "first-cp", "last-cp"] of
                [Just c , Nothing, Nothing] -> [c]
                [Nothing, Just c1, Just c2] -> [c1..c2]
                _                           -> undefined

        _name                       =                  psm!"na"
        _generalCategory            = read           $ psm!"gc"
        _nfd_qc                     = readYN         $ psm!"NFD_QC"
        _nfkd_qc                    = readYN         $ psm!"NFKD_QC"
        _nfc_qc                     = readQCValue    $ psm!"NFC_QC"
        _nfkc_qc                    = readQCValue    $ psm!"NFKC_QC"
        _upper                      = readYN         $ psm!"Upper"
        _otherUpper                 = readYN         $ psm!"OUpper"
        _lower                      = readYN         $ psm!"Lower"
        _otherLower                 = readYN         $ psm!"OLower"
        _combiningClass             = read           $ psm!"ccc"
        _dash                       = readYN         $ psm!"Dash"
        _hyphen                     = readYN         $ psm!"Hyphen"
        _quotationMark              = readYN         $ psm!"QMark"
        _terminalPunctuation        = readYN         $ psm!"Term"
        _diactric                   = readYN         $ psm!"Dia"
        _extender                   = readYN         $ psm!"Ext"
        _decomposition              = readDecomp     $ psm!"dm"
        _decompositionType          = readDecompType $ psm!"dt"
        _fullDecompositionExclusion = readYN         $ psm!"Comp_Ex"
toProp _ = undefined

-- | Extract char properties from UCD XML file
xmlToProps :: FilePath -> FilePath -> IO [(Char, CharProps)]
xmlToProps src dst = do
  input <- readFile src
  let props = concatMap toProp (filter isChar $ parseTags input)
              :: [(Char,CharProps)]
  props `deepseq` writeBinary dst props
  return props

  where isChar (TagOpen "char" _) = True
        isChar _                  = False

-- | Convert the unicode data file (ucd.all.flat.xml) to Haskell data
-- structures
processFile :: FilePath -> FilePath -> IO ()
processFile src outdir = do
    props <- (readSavedProps dst
              `catch` \(_e::IOException) -> xmlToProps src dst)
    -- print $ length props
    emitFile "Decomposable"    $ genDecomposable   Canonical props
    emitFile "DecomposableK"   $ genDecomposable   Kompat    props

    emitFile "Decompositions"   $ genDecompositions props
    emitFile "DecompositionsK"  $ genDecompositionsK props
    emitFile "DecompositionsK2" $ genDecompositionsK2 props

    emitFile "Compositions"    $ genCompositions   props
    emitFile "CombiningClass"  $ genCombiningClass props

    where
        -- properties db file
        dst = src -<.> ".pdb"
        emitFile name gen =
            writeFile (outdir <> "/" <> name <> ".hs") $ gen name

main :: IO ()
main = withCli processFile
