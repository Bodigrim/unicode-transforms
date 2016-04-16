-- |
-- Module      : Data.Text.NormalizeNative
-- Copyright   : (c) 2016 Harendra Kumar
--
-- License     : BSD-style
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
-- Experimenting with haskell native decomposition implementation
--
module Data.Text.NormalizeNative
    (
    module Data.Unicode.Normalize
    -- * Normalization
    , normalize
    ) where

--import           Data.Unicode.Internal.Normalization (decompose)
import           Data.Unicode.Normalize   (NormalizationMode (..))
import           Data.Text                      as T

-- | Perform Unicode normalization on a @Text@ according to the specified
-- normalization mode.
normalize :: NormalizationMode -> Text -> Text
normalize mode txt =
    case mode of
         NFD  -> txt
