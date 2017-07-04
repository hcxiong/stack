{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PackageImports        #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE ConstraintKinds #-}
-- Load information on package sources
module Stack.Build.Source
    ( loadSourceMap
    , loadSourceMapFull
    , SourceMap
    , PackageSource (..)
    , getLocalFlags
    , getGhcOptions
    , addUnlistedToBuildCache
    , getDefaultPackageConfig
    , getPackageConfig
    ) where

import              Control.Applicative
import              Control.Arrow ((&&&))
import              Control.Monad hiding (sequence)
import              Control.Monad.IO.Unlift
import              Control.Monad.Logger
import              Control.Monad.Reader (MonadReader)
import              Crypto.Hash (Digest, SHA256(..))
import              Crypto.Hash.Conduit (sinkHash)
import qualified    Data.ByteArray as Mem (convert)
import qualified    Data.ByteString as S
import              Data.Conduit (($$), ZipSink (..))
import qualified    Data.Conduit.Binary as CB
import qualified    Data.Conduit.List as CL
import              Data.Either (partitionEithers)
import              Data.Function
import qualified    Data.HashSet as HashSet
import              Data.List
import qualified    Data.Map as Map
import              Data.Map.Strict (Map)
import qualified    Data.Map.Strict as M
import              Data.Maybe
import              Data.Monoid
import              Data.Set (Set)
import qualified    Data.Set as Set
import              Data.Text (Text)
import              Data.Traversable (sequence)
import              Distribution.Package (pkgName, pkgVersion)
import              Distribution.PackageDescription (GenericPackageDescription, package, packageDescription)
import qualified    Distribution.PackageDescription as C
import              Path
import              Path.IO
import              Prelude hiding (sequence)
import              Stack.Build.Cache
import              Stack.Build.Target
import              Stack.Config (getLocalPackages)
import              Stack.Constants (wiredInPackages)
import              Stack.Fetch (withCabalLoader)
import              Stack.Package
import              Stack.PackageIndex (getPackageVersions)
import              Stack.Types.Build
import              Stack.Types.BuildPlan
import              Stack.Types.Config
import              Stack.Types.FlagName
import              Stack.Types.Package
import              Stack.Types.PackageIdentifier
import              Stack.Types.PackageName
import              Stack.Types.StackT
import              Stack.Types.Version
import qualified    System.Directory as D
import              System.FilePath (takeFileName)
import              System.IO (withBinaryFile, IOMode (ReadMode))
import              System.IO.Error (isDoesNotExistError)

-- | Like 'loadSourceMapFull', but doesn't return values that aren't as
-- commonly needed.
loadSourceMap :: (StackM env m, HasEnvConfig env)
              => NeedTargets
              -> BuildOptsCLI
              -> m ( [LocalPackage]
                   , SourceMap
                   )
loadSourceMap needTargets boptsCli = do
    (_, _, locals, _, sourceMap) <- loadSourceMapFull needTargets boptsCli
    return (locals, sourceMap)

-- | Given the build commandline options, does the following:
--
-- * Parses the build targets.
--
-- * Loads the 'LoadedSnapshot' from the resolver, with extra-deps
--   shadowing any packages that should be built locally.
--
-- * Loads up the 'LocalPackage' info.
--
-- * Builds a 'SourceMap', which contains info for all the packages that
--   will be involved in the build.
loadSourceMapFull :: (StackM env m, HasEnvConfig env)
                  => NeedTargets
                  -> BuildOptsCLI
                  -> m ( Map PackageName Target
                       , LoadedSnapshot
                       , [LocalPackage]
                       , Set PackageName -- non-project targets
                       , SourceMap
                       )
loadSourceMapFull needTargets boptsCli = do
    bconfig <- view buildConfigL
    (ls, localDeps, targets) <- parseTargets needTargets boptsCli
    lp <- getLocalPackages
    locals <- mapM (loadLocalPackage boptsCli targets) $ Map.toList $ lpProject lp
    -- FIXME checkFlagsUsed boptsCli locals extraDeps0 (lsPackages ls0)
    checkComponentsBuildable locals

    -- TODO for extra sanity, confirm that the targets we threw away are all TargetAll
    let nonProjectTargets = Map.keysSet targets `Set.difference` Map.keysSet (lpProject lp)

    -- Combine the local packages, extra-deps, and LoadedSnapshot into
    -- one unified source map.
    let sourceMap = Map.unions
            [ Map.fromList $ map (\lp -> (packageName $ lpPackage lp, PSLocal lp)) locals
            , flip Map.mapWithKey localDeps $ \n lpi ->
                let configOpts = getGhcOptions bconfig boptsCli n False False
                 in PSUpstream (lpiVersion lpi) Local (lpiFlags lpi) (lpiGhcOptions lpi ++ configOpts) (lpiLocation lpi)
            , flip Map.mapWithKey (lsPackages ls) $ \n lpi ->
                let configOpts = getGhcOptions bconfig boptsCli n False False
                 in PSUpstream (lpiVersion lpi) Snap (lpiFlags lpi) (lpiGhcOptions lpi ++ configOpts) (lpiLocation lpi)
            ]
            `Map.difference` Map.fromList (map (, ()) (HashSet.toList wiredInPackages))

    return
      ( targets
      , ls
      , locals
      , nonProjectTargets
      , sourceMap
      )

    {- FIXME
    let
        shadowed = Map.keysSet (lpProject lp) <> Map.keysSet extraDeps0

        -- Ignores all packages in the LoadedSnapshot that depend on any
        -- local packages or extra-deps. All packages that have
        -- transitive dependenceis on these packages are treated as
        -- extra-deps (extraDeps1).
        (ls, extraDeps1) = (ls0, Map.empty) -- FIXME confirm that shadowing is already handled before this step. shadowLoadedSnapshot ls0 shadowed

        -- Combine the extra-deps with the ones implicitly shadowed.
        extraDeps2 = extraDeps0 {- FIXME
        extraDeps2 = Map.union
            (Map.fromList (map ((\pir -> (pirName pir, (pirVersion pir, Map.empty, [])))) (HashSet.toList extraDeps0)))
            (Map.map (\lpi ->
                        let mpd = lpiDef lpi
                            triple =
                              ( lpiVersion lpi
                              , maybe Map.empty pdFlags mpd
                              , maybe [] pdGhcOptions mpd
                              )
                         in triple) extraDeps1)
            -}

        -- Add flag and ghc-option settings from the config file / cli
        extraDeps3 = Map.mapWithKey
            (error "extraDeps3")
            {-
            (\n (v, flags0, ghcOptions0) ->
                let flags =
                        case ( Map.lookup (Just n) $ boptsCLIFlags boptsCli
                             , Map.lookup Nothing $ boptsCLIFlags boptsCli
                             , Map.lookup n $ bcFlags bconfig
                             ) of
                            -- Didn't have any flag overrides, fall back to the flags
                            -- defined in the snapshot.
                            (Nothing, Nothing, Nothing) -> flags0
                            -- Either command line flag for this package, general
                            -- command line flag, or flag in stack.yaml is defined.
                            -- Take all of those and ignore the snapshot flags.
                            (x, y, z) -> Map.unions
                                [ fromMaybe Map.empty x
                                , fromMaybe Map.empty y
                                , fromMaybe Map.empty z
                                ]
                    ghcOptions =
                        ghcOptions0 ++
                        getGhcOptions bconfig boptsCli n False False
                 -- currently have no ability for extra-deps to specify their
                 -- cabal file hashes
                in PSUpstream v Local flags ghcOptions Nothing)
            -}
            extraDeps2
    -}

-- | All flags for a local package.
getLocalFlags
    :: BuildConfig
    -> BuildOptsCLI
    -> PackageName
    -> Map FlagName Bool
getLocalFlags bconfig boptsCli name = Map.unions
    [ Map.findWithDefault Map.empty (Just name) cliFlags
    , Map.findWithDefault Map.empty Nothing cliFlags
    , Map.findWithDefault Map.empty name (bcFlags bconfig)
    ]
  where
    cliFlags = boptsCLIFlags boptsCli

-- | Get the configured options to pass from GHC, based on the build
-- configuration and commandline.
getGhcOptions :: BuildConfig -> BuildOptsCLI -> PackageName -> Bool -> Bool -> [Text]
getGhcOptions bconfig boptsCli name isTarget isLocal = concat
    [ ghcOptionsFor name (configGhcOptions config)
    , concat [["-fhpc"] | isLocal && toCoverage (boptsTestOpts bopts)]
    , if boptsLibProfile bopts || boptsExeProfile bopts
         then ["-auto-all","-caf-all"]
         else []
    , if not $ boptsLibStrip bopts || boptsExeStrip bopts
         then ["-g"]
         else []
    , if includeExtraOptions
         then boptsCLIGhcOptions boptsCli
         else []
    ]
  where
    bopts = configBuild config
    config = view configL bconfig
    includeExtraOptions =
        case configApplyGhcOptions config of
            AGOTargets -> isTarget
            AGOLocals -> isLocal
            AGOEverything -> True

splitComponents :: [NamedComponent]
                -> (Set Text, Set Text, Set Text)
splitComponents =
    go id id id
  where
    go a b c [] = (Set.fromList $ a [], Set.fromList $ b [], Set.fromList $ c [])
    go a b c (CLib:xs) = go a b c xs
    go a b c (CExe x:xs) = go (a . (x:)) b c xs
    go a b c (CTest x:xs) = go a (b . (x:)) c xs
    go a b c (CBench x:xs) = go a b (c . (x:)) xs

-- | Upgrade the initial local package info to a full-blown @LocalPackage@
-- based on the selected components
loadLocalPackage
    :: forall m env. (StackM env m, HasEnvConfig env)
    => BuildOptsCLI
    -> Map PackageName Target
    -> (PackageName, LocalPackageView)
    -> m LocalPackage
loadLocalPackage boptsCli targets (name, lpv) = do
    let mtarget = Map.lookup name targets
    config  <- getPackageConfig boptsCli name (isJust mtarget) True
    bopts <- view buildOptsL
    let (exes, tests, benches) =
            case mtarget of
                Just (TargetComps comps) -> splitComponents $ Set.toList comps
                Just (TargetAll packageType) -> assert (packageType == ProjectPackage)
                    ( packageExes pkg
                    , if boptsTests bopts
                        then Map.keysSet (packageTests pkg)
                        else Set.empty
                    , if boptsBenchmarks bopts
                        then packageBenchmarks pkg
                        else Set.empty
                    )
                Nothing -> mempty

        toComponents e t b = Set.unions
            [ Set.map CExe e
            , Set.map CTest t
            , Set.map CBench b
            ]

        btconfig = config
            { packageConfigEnableTests = not $ Set.null tests
            , packageConfigEnableBenchmarks = not $ Set.null benches
            }
        testconfig = config
            { packageConfigEnableTests = True
            , packageConfigEnableBenchmarks = False
            }
        benchconfig = config
            { packageConfigEnableTests = False
            , packageConfigEnableBenchmarks = True
            }

        -- We resolve the package in 4 different configurations:
        --
        -- - pkg doesn't have tests or benchmarks enabled.
        --
        -- - btpkg has them enabled if they are present.
        --
        -- - testpkg has tests enabled, but not benchmarks.
        --
        -- - benchpkg has benchmarks enablde, but not tests.
        --
        -- The latter two configurations are used to compute the deps
        -- when --enable-benchmarks or --enable-tests are configured.
        -- This allows us to do an optimization where these are passed
        -- if the deps are present. This can avoid doing later
        -- unnecessary reconfigures.
        gpkg = lpvGPD lpv
        pkg = resolvePackage config gpkg
        btpkg
            | Set.null tests && Set.null benches = Nothing
            | otherwise = Just (resolvePackage btconfig gpkg)
        testpkg = resolvePackage testconfig gpkg
        benchpkg = resolvePackage benchconfig gpkg

    mbuildCache <- tryGetBuildCache $ lpvRoot lpv
    (files,_) <- getPackageFilesSimple pkg (lpvCabalFP lpv)

    (dirtyFiles, newBuildCache) <- checkBuildCache
        (fromMaybe Map.empty mbuildCache)
        (Set.toList files)

    return LocalPackage
        { lpPackage = pkg
        , lpTestDeps = packageDeps testpkg
        , lpBenchDeps = packageDeps benchpkg
        , lpTestBench = btpkg
        , lpFiles = files
        , lpForceDirty = boptsForceDirty bopts
        , lpDirtyFiles =
            if not (Set.null dirtyFiles)
                then let tryStripPrefix y =
                          fromMaybe y (stripPrefix (toFilePath $ lpvRoot lpv) y)
                      in Just $ Set.map tryStripPrefix dirtyFiles
                else Nothing
        , lpNewBuildCache = newBuildCache
        , lpCabalFile = lpvCabalFP lpv
        , lpDir = lpvRoot lpv
        , lpWanted = isJust mtarget
        , lpComponents = toComponents exes tests benches
        -- TODO: refactor this so that it's easier to be sure that these
        -- components are indeed unbuildable.
        --
        -- The reasoning here is that if the STLocalComps specification
        -- made it through component parsing, but the components aren't
        -- present, then they must not be buildable.
        , lpUnbuildable = toComponents
            (exes `Set.difference` packageExes pkg)
            (tests `Set.difference` Map.keysSet (packageTests pkg))
            (benches `Set.difference` packageBenchmarks pkg)
        }

-- | Ensure that the flags specified in the stack.yaml file and on the command
-- line are used.
checkFlagsUsed :: (MonadThrow m, MonadReader env m, HasBuildConfig env)
               => BuildOptsCLI
               -> [LocalPackage]
               -> Map PackageName (PackageLocationIndex FilePath) -- ^ extra deps
               -> Map PackageName snapshot -- ^ snapshot, for error messages
               -> m ()
checkFlagsUsed boptsCli lps extraDeps snapshot = do
    bconfig <- view buildConfigL

        -- Check if flags specified in stack.yaml and the command line are
        -- used, see https://github.com/commercialhaskell/stack/issues/617
    let flags = map (, FSCommandLine) [(k, v) | (Just k, v) <- Map.toList $ boptsCLIFlags boptsCli]
             ++ map (, FSStackYaml) (Map.toList $ bcFlags bconfig)

        localNameMap = Map.fromList $ map (packageName . lpPackage &&& lpPackage) lps
        checkFlagUsed ((name, userFlags), source) =
            case Map.lookup name localNameMap of
                -- Package is not available locally
                Nothing ->
                    if Map.member name extraDeps
                        -- We don't check for flag presence for extra deps
                        then Nothing
                        -- Also not in extra-deps, it's an error
                        else
                            case Map.lookup name snapshot of
                                Nothing -> Just $ UFNoPackage source name
                                Just _ -> Just $ UFSnapshot name
                -- Package exists locally, let's check if the flags are defined
                Just pkg ->
                    let unused = Set.difference (Map.keysSet userFlags) (packageDefinedFlags pkg)
                     in if Set.null unused
                            -- All flags are defined, nothing to do
                            then Nothing
                            -- Error about the undefined flags
                            else Just $ UFFlagsNotDefined source pkg unused

        unusedFlags = mapMaybe checkFlagUsed flags

    unless (null unusedFlags)
        $ throwM
        $ InvalidFlagSpecification
        $ Set.fromList unusedFlags

pirName :: PackageIdentifierRevision -> PackageName
pirName (PackageIdentifierRevision (PackageIdentifier name _) _) = name

pirVersion :: PackageIdentifierRevision -> Version
pirVersion (PackageIdentifierRevision (PackageIdentifier _ version) _) = version

-- | Add in necessary packages to extra dependencies
--
-- Originally part of https://github.com/commercialhaskell/stack/issues/272,
-- this was then superseded by
-- https://github.com/commercialhaskell/stack/issues/651
extendExtraDeps
    :: forall env m. (StackM env m, HasBuildConfig env)
    => Map PackageName (GenericPackageDescription, PackageLocationIndex FilePath) -- ^ original extra deps
    -> Map PackageName Version -- ^ package identifiers from the command line
    -> Set PackageName -- ^ package names (without versions) added on the command line
    -> m (Map PackageName (PackageLocationIndex FilePath)) -- ^ new extradeps
extendExtraDeps extraDeps0 cliWithVersion cliNoVersion = do
    error "extendExtraDeps" {- FIXME
    (errs, unknowns') <- fmap partitionEithers $ mapM addNoVersion $ Set.toList cliNoVersion
    case errs of
        [] -> return $ Map.unions $ extraDeps1 : unknowns'
        _ -> do
            bconfig <- view buildConfigL
            throwM $ UnknownTargets
                (Set.fromList errs)
                Map.empty -- TODO check the cliExtraDeps for presence in index
                (bcStackYaml bconfig)
  where
    extraDeps1 = Map.union (Map.map (gpdVersion . fst) extraDeps0) cliWithVersion

    -- Try adding a package name specified on the command line that does not have an associated version. We need to check if we already have this
    addNoVersion :: PackageName -> m (Either PackageName (Map PackageName PackageIdentifierRevision))
    addNoVersion pn = do
        if Map.member pn extraDeps1
            -- added by package name, and we already have it, nothing new
            then return (Right Map.empty)
            -- 
            else do
                mlatestVersion <- getLatestVersion pn
                case mlatestVersion of
                    Just v -> return (Right $ Map.singleton pn
                                    $ PackageIdentifierRevision (PackageIdentifier pn v) Nothing)
                    Nothing -> return (Left pn)

    -}

-- | Compare the current filesystem state to the cached information, and
-- determine (1) if the files are dirty, and (2) the new cache values.
checkBuildCache :: forall m. (MonadIO m)
                => Map FilePath FileCacheInfo -- ^ old cache
                -> [Path Abs File] -- ^ files in package
                -> m (Set FilePath, Map FilePath FileCacheInfo)
checkBuildCache oldCache files = do
    fileTimes <- liftM Map.fromList $ forM files $ \fp -> do
        mmodTime <- liftIO (getModTimeMaybe (toFilePath fp))
        return (toFilePath fp, mmodTime)
    liftM (mconcat . Map.elems) $ sequence $
        Map.mergeWithKey
            (\fp mmodTime fci -> Just (go fp mmodTime (Just fci)))
            (Map.mapWithKey (\fp mmodTime -> go fp mmodTime Nothing))
            (Map.mapWithKey (\fp fci -> go fp Nothing (Just fci)))
            fileTimes
            oldCache
  where
    go :: FilePath -> Maybe ModTime -> Maybe FileCacheInfo -> m (Set FilePath, Map FilePath FileCacheInfo)
    -- Filter out the cabal_macros file to avoid spurious recompilations
    go fp _ _ | takeFileName fp == "cabal_macros.h" = return (Set.empty, Map.empty)
    -- Common case where it's in the cache and on the filesystem.
    go fp (Just modTime') (Just fci)
        | fciModTime fci == modTime' = return (Set.empty, Map.empty)
        | otherwise = do
            newFci <- calcFci modTime' fp
            let isDirty =
                    fciSize fci /= fciSize newFci ||
                    fciHash fci /= fciHash newFci
                newDirty = if isDirty then Set.singleton fp else Set.empty
            return (newDirty, Map.singleton fp newFci)
    -- Missing file. Add it to dirty files, but no FileCacheInfo.
    go fp Nothing _ = return (Set.singleton fp, Map.empty)
    -- Missing cache. Add it to dirty files and compute FileCacheInfo.
    go fp (Just modTime') Nothing = do
        newFci <- calcFci modTime' fp
        return (Set.singleton fp, Map.singleton fp newFci)

-- | Returns entries to add to the build cache for any newly found unlisted modules
addUnlistedToBuildCache
    :: (StackM env m, HasEnvConfig env)
    => ModTime
    -> Package
    -> Path Abs File
    -> Map FilePath a
    -> m ([Map FilePath FileCacheInfo], [PackageWarning])
addUnlistedToBuildCache preBuildTime pkg cabalFP buildCache = do
    (files,warnings) <- getPackageFilesSimple pkg cabalFP
    let newFiles =
            Set.toList $
            Set.map toFilePath files `Set.difference` Map.keysSet buildCache
    addBuildCache <- mapM addFileToCache newFiles
    return (addBuildCache, warnings)
  where
    addFileToCache fp = do
        mmodTime <- getModTimeMaybe fp
        case mmodTime of
            Nothing -> return Map.empty
            Just modTime' ->
                if modTime' < preBuildTime
                    then do
                        newFci <- calcFci modTime' fp
                        return (Map.singleton fp newFci)
                    else return Map.empty

-- | Gets list of Paths for files in a package
getPackageFilesSimple
    :: (StackM env m, HasEnvConfig env)
    => Package -> Path Abs File -> m (Set (Path Abs File), [PackageWarning])
getPackageFilesSimple pkg cabalFP = do
    (_,compFiles,cabalFiles,warnings) <-
        getPackageFiles (packageFiles pkg) cabalFP
    return
        ( Set.map dotCabalGetPath (mconcat (M.elems compFiles)) <> cabalFiles
        , warnings)

-- | Get file modification time, if it exists.
getModTimeMaybe :: MonadIO m => FilePath -> m (Maybe ModTime)
getModTimeMaybe fp =
    liftIO
        (catch
             (liftM
                  (Just . modTime)
                  (D.getModificationTime fp))
             (\e ->
                   if isDoesNotExistError e
                       then return Nothing
                       else throwM e))

-- | Create FileCacheInfo for a file.
calcFci :: MonadIO m => ModTime -> FilePath -> m FileCacheInfo
calcFci modTime' fp = liftIO $
    withBinaryFile fp ReadMode $ \h -> do
        (size, digest) <- CB.sourceHandle h $$ getZipSink
            ((,)
                <$> ZipSink (CL.fold
                    (\x y -> x + fromIntegral (S.length y))
                    0)
                <*> ZipSink sinkHash)
        return FileCacheInfo
            { fciModTime = modTime'
            , fciSize = size
            , fciHash = Mem.convert (digest :: Digest SHA256)
            }

checkComponentsBuildable :: MonadThrow m => [LocalPackage] -> m ()
checkComponentsBuildable lps =
    unless (null unbuildable) $ throwM $ SomeTargetsNotBuildable unbuildable
  where
    unbuildable =
        [ (packageName (lpPackage lp), c)
        | lp <- lps
        , c <- Set.toList (lpUnbuildable lp)
        ]

getDefaultPackageConfig :: (MonadIO m, MonadReader env m, HasEnvConfig env)
  => m PackageConfig
getDefaultPackageConfig = do
  platform <- view platformL
  compilerVersion <- view actualCompilerVersionL
  return PackageConfig
    { packageConfigEnableTests = False
    , packageConfigEnableBenchmarks = False
    , packageConfigFlags = M.empty
    , packageConfigGhcOptions = []
    , packageConfigCompilerVersion = compilerVersion
    , packageConfigPlatform = platform
    }

-- | Get 'PackageConfig' for package given its name.
getPackageConfig :: (MonadIO m, MonadReader env m, HasEnvConfig env)
  => BuildOptsCLI
  -> PackageName
  -> Bool
  -> Bool
  -> m PackageConfig
getPackageConfig boptsCli name isTarget isLocal = do
  bconfig <- view buildConfigL
  platform <- view platformL
  compilerVersion <- view actualCompilerVersionL
  return PackageConfig
    { packageConfigEnableTests = False
    , packageConfigEnableBenchmarks = False
    , packageConfigFlags = getLocalFlags bconfig boptsCli name
    , packageConfigGhcOptions = getGhcOptions bconfig boptsCli name isTarget isLocal
    , packageConfigCompilerVersion = compilerVersion
    , packageConfigPlatform = platform
    }
