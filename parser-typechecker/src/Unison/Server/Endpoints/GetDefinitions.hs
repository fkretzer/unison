{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Unison.Server.Endpoints.GetDefinitions where

import Control.Error (runExceptT)
import qualified Data.Text as Text
import Servant
  ( QueryParam,
    QueryParams,
    throwError,
    (:>),
  )
import Servant.Docs
  ( DocQueryParam (..),
    ParamKind (..),
    ToParam (..),
    ToSample (..),
    noSamples,
  )
import Servant.Server (Handler)
import Unison.Codebase (Codebase)
import qualified Unison.Codebase.Path as Path
import qualified Unison.Codebase.Runtime as Rt
import Unison.Codebase.ShortBranchHash
  ( ShortBranchHash,
  )
import qualified Unison.HashQualified as HQ
import Unison.Parser (Ann)
import Unison.Prelude
import qualified Unison.Server.Backend as Backend
import Unison.Server.Errors
  ( backendError,
    badNamespace,
  )
import Unison.Server.Types
  ( APIGet,
    APIHeaders,
    DefinitionDisplayResults,
    HashQualifiedName,
    NamespaceFQN,
    Suffixify (..),
    addHeaders,
    defaultWidth,
  )
import Unison.Util.Pretty (Width)
import Unison.Var (Var)

type DefinitionsAPI =
  "getDefinition" :> QueryParam "rootBranch" ShortBranchHash
                  :> QueryParam "relativeTo" NamespaceFQN
                  :> QueryParams "names" HashQualifiedName
                  :> QueryParam "renderWidth" Width
                  :> QueryParam "suffixifyBindings" Suffixify
  :> APIGet DefinitionDisplayResults

instance ToParam (QueryParam "renderWidth" Width) where
  toParam _ = DocQueryParam
    "renderWidth"
    ["80", "100", "120"]
    (  "The preferred maximum line width (in characters) of the source code of "
    <> "definitions to be rendered. "
    <> "If left absent, the render width is assumed to be "
    <> show defaultWidth
    <> "."
    )
    Normal

instance ToParam (QueryParam "suffixifyBindings" Suffixify) where
  toParam _ = DocQueryParam
    "suffixifyBindings"
    ["True", "False"]
    (  "If True or absent, renders definitions using the shortest unambiguous "
    <> "suffix. If False, uses the fully qualified name. "
    )
    Normal


instance ToParam (QueryParam "relativeTo" NamespaceFQN) where
  toParam _ = DocQueryParam
    "relativeTo"
    [".", ".base", "foo.bar"]
    ("The namespace relative to which names will be resolved and displayed. "
    <> "If left absent, the root namespace will be used."
    )
    Normal

instance ToParam (QueryParam "rootBranch" ShortBranchHash) where
  toParam _ = DocQueryParam
    "rootBranch"
    ["#abc123"]
    (  "The hash or hash prefix of the namespace root. "
    <> "If left absent, the most recent root will be used."
    )
    Normal

instance ToParam (QueryParams "names" Text) where
  toParam _ = DocQueryParam
    "names"
    [".base.List", "foo.bar", "#abc123"]
    ("A fully qualified name, hash-qualified name, " <> "or hash.")
    List

instance ToSample DefinitionDisplayResults where
  toSamples _ = noSamples

serveDefinitions
  :: Var v
  => Handler ()
  -> Rt.Runtime v
  -> Codebase IO v Ann
  -> Maybe ShortBranchHash
  -> Maybe NamespaceFQN
  -> [HashQualifiedName]
  -> Maybe Width
  -> Maybe Suffixify
  -> Handler (APIHeaders DefinitionDisplayResults)
serveDefinitions h rt codebase mayRoot relativePath hqns width suff =
  addHeaders <$> do
    h
    rel <-
      fmap Path.fromPath' <$> traverse (parsePath . Text.unpack) relativePath
    ea <- liftIO . runExceptT $ do
      root <- traverse (Backend.expandShortBranchHash codebase) mayRoot
      Backend.prettyDefinitionsBySuffixes rel
                                          root
                                          width
                                          (fromMaybe (Suffixify True) suff)
                                          rt
                                          codebase
        $   HQ.unsafeFromText
        <$> hqns
    errFromEither backendError ea
 where
  parsePath p = errFromEither (`badNamespace` p) $ Path.parsePath' p
  errFromEither f = either (throwError . f) pure
