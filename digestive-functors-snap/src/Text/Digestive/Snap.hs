-- | Module providing a Snap backend for the digestive-functors library
module Text.Digestive.Snap
    ( SnapPartPolicy
    , SnapFormConfig (..)
    , defaultSnapFormConfig
    , runForm
    , runFormWith
    ) where

import Control.Applicative ((<$>))
import Control.Monad.Trans (liftIO)
import Data.Maybe (catMaybes, fromMaybe)
import System.Directory (copyFile, getTemporaryDirectory)
import System.FilePath (takeFileName, (</>))
import qualified Data.Map as M

import Data.Text (Text)
import qualified Data.ByteString.Char8 as B
import qualified Data.Text.Encoding as T
import qualified Snap.Core as Snap
import qualified Snap.Util.FileUploads as Snap

import Text.Digestive.Form
import Text.Digestive.Form.Encoding
import Text.Digestive.Types
import Text.Digestive.View

type SnapPartPolicy = Snap.PartInfo -> Snap.PartUploadPolicy

data SnapFormConfig = SnapFormConfig
    { -- | Can be used to override the method detected by Snap, in case you e.g.
      -- want to perform a 'postForm' even in case of a GET request.
      method             :: Maybe Method
    , temporaryDirectory :: Maybe FilePath
    , uploadPolicy       :: Snap.UploadPolicy
    , partPolicy         :: SnapPartPolicy
    }

defaultSnapFormConfig :: SnapFormConfig
defaultSnapFormConfig = SnapFormConfig
    { method             = Nothing
    , temporaryDirectory = Nothing
    , uploadPolicy       = Snap.defaultUploadPolicy
    , partPolicy         = const $ Snap.allowWithMaximumSize (128 * 1024)
    }

snapEnv :: Snap.MonadSnap m => [(Text, FilePath)] -> Env m
snapEnv allFiles path = do
    inputs <- map (TextInput . T.decodeUtf8) . findParams <$> Snap.getParams
    let files = map (FileInput . snd) $ filter ((== name) . fst) allFiles
    return $ inputs ++ files
  where
    findParams = fromMaybe [] . M.lookup (T.encodeUtf8 name)
    name       = fromPath path

-- | Deals with uploaded files, by placing each file in the temporary directory
-- specified in the configuration. It returns a mapping of names to the
-- temporary files.
snapFiles :: Snap.MonadSnap m => SnapFormConfig -> m [(Text, FilePath)]
snapFiles config = do
    -- Get the temporary dir or use the one provided by the OS
    tmpDir <- liftIO $ maybe getTemporaryDirectory return $
        temporaryDirectory config

    -- Actually do the work...
    files <- Snap.handleFileUploads tmpDir (uploadPolicy config) (partPolicy config) $
         (storeFile tmpDir)
    return $ catMaybes files
  where
    storeFile _   _        (Left _)     = return Nothing
    storeFile tmp partinfo (Right path) = do
        let newPath = tmp </> "_" ++ takeFileName path ++
                maybe "" B.unpack (Snap.partFileName partinfo)
        copyFile path newPath
        return $ Just (T.decodeUtf8 $ Snap.partFieldName partinfo, newPath)

-- | Runs a form with the HTTP input provided by Snap.
--
-- Automatically picks between 'getForm' and 'postForm' based on the request
-- method. Set 'method' in the 'SnapFormConfig' to override this behaviour.
runForm :: Snap.MonadSnap m
        => Text                 -- ^ Name for the form
        -> Form v m a           -- ^ Form to run
        -> m (View v, Maybe a)  -- ^ Result
runForm = runFormWith defaultSnapFormConfig

-- | Runs a form with a custom upload policy, and HTTP input from snap.
--
-- Automatically picks between 'getForm' and 'postForm' based on request
-- method. Set 'method' in the 'SnapFormConfig' to override this behaviour.
runFormWith :: Snap.MonadSnap m
            => SnapFormConfig       -- ^ Tempdir and upload policies
            -> Text                 -- ^ Name for the form
            -> Form v m a           -- ^ Form to run
            -> m (View v, Maybe a)  -- ^ Result
runFormWith config name form = do
    m <- maybe snapMethod return (method config)
    case m of
        Get  -> do
            view <- getForm name form
            return (view, Nothing)
        Post ->
            postForm name form $ \encType -> case encType of
                UrlEncoded -> return $ snapEnv []
                MultiPart  -> snapEnv <$> snapFiles config
  where
    snapMethod        = toMethod . Snap.rqMethod <$> Snap.getRequest
    toMethod Snap.GET = Get
    toMethod _        = Post
