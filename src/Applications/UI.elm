module UI exposing (main)

import Alien
import Authentication
import Authentication.RemoteStorage
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Chunky exposing (..)
import Color
import Color.Ext as Color
import Common exposing (Switch(..))
import Conditional exposing (..)
import ContextMenu exposing (ContextMenu)
import Css exposing (url)
import Css.Global
import Css.Transitions
import Debouncer.Basic as Debouncer
import Dict.Ext as Dict
import File
import File.Download
import File.Select
import Html.Events.Extra.Pointer as Pointer
import Html.Styled as Html exposing (Html, section, toUnstyled)
import Html.Styled.Attributes exposing (css, id)
import Html.Styled.Events exposing (onClick)
import Html.Styled.Lazy as Lazy
import Json.Decode
import Json.Encode
import List.Extra as List
import Maybe.Extra as Maybe
import Notifications
import Process
import Return2 exposing (..)
import Return3
import Sources
import Sources.Encoding
import Sources.Services.Dropbox
import Sources.Services.Google
import Tachyons.Classes as T
import Task
import Time
import Tracks.Encoding
import UI.Authentication as Authentication
import UI.Authentication.ContextMenu as Authentication
import UI.Backdrop as Backdrop
import UI.Console
import UI.ContextMenu
import UI.Core as Core exposing (Flags, Model, Msg(..))
import UI.Equalizer as Equalizer
import UI.Kit
import UI.Navigation as Navigation
import UI.Notifications
import UI.Page as Page
import UI.Ports as Ports
import UI.Queue as Queue
import UI.Queue.Common
import UI.Queue.Core as Queue
import UI.Reply as Reply exposing (Reply(..))
import UI.Settings as Settings
import UI.Settings.Page
import UI.Sources as Sources
import UI.Sources.ContextMenu as Sources
import UI.Sources.Form
import UI.Sources.Page
import UI.Svg.Elements
import UI.Tracks as Tracks
import UI.Tracks.ContextMenu as Tracks
import UI.Tracks.Core as Tracks
import UI.UserData as UserData
import Url exposing (Url)



-- ⛩


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }



-- 🌳


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        maybePage =
            Page.fromUrl url

        page =
            Maybe.withDefault Page.Index maybePage
    in
    { contextMenu = Nothing
    , currentTime = Time.millisToPosix flags.initialTime
    , isLoading = True
    , navKey = key
    , notifications = []
    , page = page
    , url = url
    , viewport = flags.viewport

    -- Audio
    --------
    , audioDuration = 0
    , audioHasStalled = False
    , audioIsLoading = False
    , audioIsPlaying = False

    -- Children
    -----------
    , authentication = Authentication.initialModel url
    , backdrop = Backdrop.initialModel
    , equalizer = Equalizer.initialModel
    , queue = Queue.initialModel
    , sources = Sources.initialModel
    , tracks = Tracks.initialModel

    -- Debouncing
    -------------
    , debounce =
        0.25
            |> Debouncer.fromSeconds
            |> Debouncer.debounce
            |> Debouncer.toDebouncer
    }
        |> update
            (PageChanged page)
        |> addCommand
            (case maybePage of
                Just _ ->
                    Cmd.none

                Nothing ->
                    Nav.replaceUrl key "/"
            )



-- 📣


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Bypass ->
            return model

        Debounce debouncerMsg ->
            Return3.wieldNested
                update
                { mapCmd = Debounce
                , mapModel = \child -> { model | debounce = child }
                , update = \m -> Debouncer.update m >> Return3.fromDebouncer
                }
                { model = model.debounce
                , msg = debouncerMsg
                }

        LoadEnclosedUserData json ->
            model
                |> UserData.importEnclosed json
                |> Return3.wield translateReply

        LoadHypaethralUserData json ->
            model
                |> UserData.importHypaethral json
                |> Return3.wield translateReply

        ResizedWindow ( width, height ) ->
            { height = toFloat height
            , width = toFloat width
            }
                |> (\v -> { model | contextMenu = Nothing, viewport = v })
                |> return

        SetCurrentTime time ->
            let
                sources =
                    model.sources
            in
            ( { model
                | currentTime = time
                , sources = { sources | currentTime = time }
              }
            , Cmd.none
            )

        Core.ToggleLoadingScreen On ->
            return { model | isLoading = True }

        Core.ToggleLoadingScreen Off ->
            return { model | isLoading = False }

        -----------------------------------------
        -- Audio
        -----------------------------------------
        Pause ->
            returnWithModel model (Ports.pause ())

        Play ->
            returnWithModel model (Ports.play ())

        Seek percentage ->
            returnWithModel model (Ports.seek percentage)

        SetAudioDuration duration ->
            return { model | audioDuration = duration }

        SetAudioHasStalled hasStalled ->
            return { model | audioHasStalled = hasStalled }

        SetAudioIsLoading isLoading ->
            return { model | audioIsLoading = isLoading }

        SetAudioIsPlaying isPlayinh ->
            return { model | audioIsPlaying = isPlayinh }

        Unstall ->
            returnWithModel model (Ports.unstall ())

        -----------------------------------------
        -- Authentication
        -----------------------------------------
        RemoteStorageWebfinger remoteStorage (Ok oauthOrigin) ->
            let
                origin =
                    Common.urlOrigin model.url
            in
            remoteStorage
                |> Authentication.RemoteStorage.oauthAddress
                    { oauthOrigin = oauthOrigin
                    , origin = origin
                    }
                |> Nav.load
                |> returnWithModel model

        RemoteStorageWebfinger _ (Err _) ->
            UI.Notifications.show
                (Notifications.error Authentication.RemoteStorage.webfingerError)
                model

        -----------------------------------------
        -- Brain
        -----------------------------------------
        SignOut ->
            { model
                | authentication = Authentication.initialModel model.url
                , sources = Sources.initialModel
                , tracks = Tracks.initialModel
            }
                |> update (BackdropMsg Backdrop.Default)
                |> addCommand (Ports.toBrain <| Alien.trigger Alien.SignOut)
                |> addCommand (Nav.pushUrl model.navKey "/")

        -----------------------------------------
        -- Children
        -----------------------------------------
        AuthenticationMsg sub ->
            Return3.wieldNested
                translateReply
                { mapCmd = AuthenticationMsg
                , mapModel = \child -> { model | authentication = child }
                , update = Authentication.update
                }
                { model = model.authentication
                , msg = sub
                }

        BackdropMsg sub ->
            Return3.wieldNested
                translateReply
                { mapCmd = BackdropMsg
                , mapModel = \child -> { model | backdrop = child }
                , update = Backdrop.update
                }
                { model = model.backdrop
                , msg = sub
                }

        EqualizerMsg sub ->
            Return3.wieldNested
                translateReply
                { mapCmd = EqualizerMsg
                , mapModel = \child -> { model | equalizer = child }
                , update = Equalizer.update
                }
                { model = model.equalizer
                , msg = sub
                }

        QueueMsg sub ->
            Return3.wieldNested
                translateReply
                { mapCmd = QueueMsg
                , mapModel = \child -> { model | queue = child }
                , update = Queue.update
                }
                { model = model.queue
                , msg = sub
                }

        SourcesMsg sub ->
            Return3.wieldNested
                translateReply
                { mapCmd = SourcesMsg
                , mapModel = \child -> { model | sources = child }
                , update = Sources.update
                }
                { model = model.sources
                , msg = sub
                }

        TracksMsg sub ->
            Return3.wieldNested
                translateReply
                { mapCmd = TracksMsg
                , mapModel = \child -> { model | tracks = child }
                , update = Tracks.update
                }
                { model = model.tracks
                , msg = sub
                }

        -----------------------------------------
        -- Context Menu
        -----------------------------------------
        HideContextMenu ->
            return { model | contextMenu = Nothing }

        -----------------------------------------
        -- Import / Export
        -----------------------------------------
        Export ->
            { favourites = model.tracks.favourites
            , settings = Just (UserData.gatherSettings model)
            , sources = model.sources.collection
            , tracks = model.tracks.collection.untouched
            }
                |> Authentication.encodeHypaethral
                |> Json.Encode.encode 2
                |> File.Download.string "diffuse.json" "application/json"
                |> returnWithModel model

        Import file ->
            250
                |> Process.sleep
                |> Task.andThen (\_ -> File.toString file)
                |> Task.perform ImportJson
                |> returnWithModel { model | isLoading = True }

        ImportJson json ->
            let
                notification =
                    Notifications.success "Imported data successfully!"
            in
            model
                |> update
                    (json
                        |> Json.Decode.decodeString Json.Decode.value
                        |> Result.withDefault Json.Encode.null
                        |> LoadHypaethralUserData
                    )
                |> andThen (translateReply SaveFavourites)
                |> andThen (translateReply SaveSources)
                |> andThen (translateReply SaveTracks)
                |> andThen (update <| ShowNotification notification)
                |> andThen (update <| ChangeUrlUsingPage Page.Index)

        RequestImport ->
            Import
                |> File.Select.file [ "application/json" ]
                |> returnWithModel model

        -----------------------------------------
        -- Notifications
        -----------------------------------------
        Core.DismissNotification args ->
            UI.Notifications.dismiss model args

        RemoveNotification { id } ->
            model.notifications
                |> List.filter (Notifications.id >> (/=) id)
                |> (\notifications -> { model | notifications = notifications })
                |> return

        ShowNotification notification ->
            UI.Notifications.show notification model

        -----------------------------------------
        -- Page Transitions
        -----------------------------------------
        PageChanged (Page.Sources (UI.Sources.Page.NewThroughRedirect service args)) ->
            let
                ( sources, form, defaultContext ) =
                    ( model.sources
                    , model.sources.form
                    , UI.Sources.Form.defaultContext
                    )
            in
            { defaultContext
                | data =
                    case service of
                        Sources.Dropbox ->
                            Sources.Services.Dropbox.authorizationSourceData args

                        Sources.Google ->
                            Sources.Services.Google.authorizationSourceData args

                        _ ->
                            defaultContext.data
                , service =
                    service
            }
                |> (\c -> { form | context = c, step = UI.Sources.Form.How })
                |> (\f -> { sources | form = f })
                |> (\s -> { model | sources = s })
                |> return

        PageChanged (Page.Sources (UI.Sources.Page.Edit sourceId)) ->
            let
                isLoading =
                    model.isLoading

                maybeSource =
                    List.find (.id >> (==) sourceId) model.sources.collection
            in
            case ( isLoading, maybeSource ) of
                ( False, Just source ) ->
                    let
                        ( sources, form ) =
                            ( model.sources
                            , model.sources.form
                            )

                        newForm =
                            { form | context = source }

                        newSources =
                            { sources | form = newForm }
                    in
                    return { model | sources = newSources }

                ( False, Nothing ) ->
                    return model

                ( True, _ ) ->
                    -- Redirect away from edit-source page
                    UI.Sources.Page.Index
                        |> Page.Sources
                        |> ChangeUrlUsingPage
                        |> updateWithModel model

        PageChanged _ ->
            return model

        -----------------------------------------
        -- URL
        -----------------------------------------
        ChangeUrlUsingPage page ->
            page
                |> Page.toString
                |> Nav.pushUrl model.navKey
                |> returnWithModel model

        LinkClicked (Browser.Internal url) ->
            if url.path == "/about" then
                returnWithModel model (Nav.load "/about")

            else
                returnWithModel model (Nav.pushUrl model.navKey <| Url.toString url)

        LinkClicked (Browser.External href) ->
            returnWithModel model (Nav.load href)

        UrlChanged url ->
            case Page.fromUrl url of
                Just page ->
                    { model | page = page, url = url }
                        |> return
                        |> andThen (update <| PageChanged page)

                Nothing ->
                    returnWithModel model (Nav.replaceUrl model.navKey "/")


updateWithModel : Model -> Msg -> ( Model, Cmd Msg )
updateWithModel model msg =
    update msg model



-- 📣  ░░  CHILDREN & REPLIES


translateReply : Reply -> Model -> ( Model, Cmd Msg )
translateReply reply model =
    case reply of
        ExternalAuth (Authentication.RemoteStorage _) input ->
            input
                |> Authentication.RemoteStorage.parseUserAddress
                |> Maybe.map
                    (Authentication.RemoteStorage.webfingerRequest RemoteStorageWebfinger)
                |> Maybe.unwrap
                    (UI.Notifications.show
                        (Notifications.error Authentication.RemoteStorage.userAddressError)
                        model
                    )
                    (returnWithModel model)

        ExternalAuth _ _ ->
            return model

        GoToPage page ->
            page
                |> ChangeUrlUsingPage
                |> updateWithModel model

        Reply.ToggleLoadingScreen state ->
            update (Core.ToggleLoadingScreen state) model

        -----------------------------------------
        -- Context Menu
        -----------------------------------------
        ShowMoreAuthenticationOptions coordinates ->
            return { model | contextMenu = Just (Authentication.moreOptionsMenu coordinates) }

        ShowSourceContextMenu coordinates source ->
            return { model | contextMenu = Just (Sources.sourceMenu source coordinates) }

        ShowTracksContextMenu coordinates tracks ->
            return { model | contextMenu = Just (Tracks.trackMenu tracks coordinates) }

        -----------------------------------------
        -- Notifications
        -----------------------------------------
        Reply.DismissNotification options ->
            UI.Notifications.dismiss model options

        ShowErrorNotification string ->
            UI.Notifications.show (Notifications.stickyError string) model

        ShowSuccessNotification string ->
            UI.Notifications.show (Notifications.success string) model

        ShowWarningNotification string ->
            UI.Notifications.show (Notifications.stickyWarning string) model

        -----------------------------------------
        -- Queue
        -----------------------------------------
        ActiveQueueItemChanged maybeQueueItem ->
            let
                nowPlaying =
                    Maybe.map .identifiedTrack maybeQueueItem

                portCmd =
                    maybeQueueItem
                        |> Maybe.map .identifiedTrack
                        |> Maybe.map
                            (UI.Queue.Common.makeEngineItem
                                model.currentTime
                                model.sources.collection
                            )
                        |> Ports.activeQueueItemChanged
            in
            model
                |> update (TracksMsg <| Tracks.SetNowPlaying nowPlaying)
                |> addCommand portCmd

        FillQueue ->
            model.tracks.collection.harvested
                |> Queue.Fill model.currentTime
                |> QueueMsg
                |> updateWithModel model

        PlayTrack identifiedTrack ->
            identifiedTrack
                |> Queue.InjectFirstAndPlay
                |> QueueMsg
                |> updateWithModel model

        ResetQueue ->
            update (QueueMsg Queue.Reset) model

        ShiftQueue ->
            update (QueueMsg Queue.Shift) model

        -----------------------------------------
        -- Sources & Tracks
        -----------------------------------------
        AddSourceToCollection source ->
            source
                |> Sources.AddToCollection
                |> SourcesMsg
                |> updateWithModel model

        ExternalSourceAuthorization urlBuilder ->
            model.url
                |> Common.urlOrigin
                |> urlBuilder
                |> Nav.load
                |> returnWithModel model

        ProcessSources ->
            let
                notification =
                    Notifications.warning "Processing sources …"

                notificationId =
                    Notifications.id notification

                sources =
                    model.sources

                newSources =
                    { sources | processingNotificationId = Just notificationId }
            in
            [ ( "origin"
              , Json.Encode.string (Common.urlOrigin model.url)
              )
            , ( "sources"
              , Json.Encode.list Sources.Encoding.encode model.sources.collection
              )
            , ( "tracks"
              , Json.Encode.list Tracks.Encoding.encodeTrack model.tracks.collection.untouched
              )
            ]
                |> Json.Encode.object
                |> Alien.broadcast Alien.ProcessSources
                |> Ports.toBrain
                |> returnWithModel { model | sources = newSources }
                |> andThen (UI.Notifications.show notification)

        RemoveTracksWithSourceId sourceId ->
            sourceId
                |> Tracks.RemoveBySourceId
                |> TracksMsg
                |> updateWithModel model

        ReplaceSourceInCollection source ->
            let
                sources =
                    model.sources
            in
            model.sources.collection
                |> List.map (\s -> ifThenElse (s.id == source.id) source s)
                |> (\c -> { sources | collection = c })
                |> (\s -> { model | sources = s })
                |> return
                |> andThen (translateReply SaveSources)

        -----------------------------------------
        -- User Data
        -----------------------------------------
        InsertDemo ->
            model
                |> update (LoadHypaethralUserData UserData.demo)
                |> andThen (translateReply SaveFavourites)
                |> andThen (translateReply SaveSources)
                |> andThen (translateReply SaveTracks)

        SaveEnclosedUserData ->
            model
                |> UserData.exportEnclosed
                |> Alien.broadcast Alien.SaveEnclosedUserData
                |> Ports.toBrain
                |> returnWithModel model

        SaveFavourites ->
            model
                |> UserData.encodedFavourites
                |> Alien.broadcast Alien.SaveFavourites
                |> Ports.toBrain
                |> returnWithModel model

        SaveSettings ->
            model
                |> UserData.gatherSettings
                |> Authentication.encodeSettings
                |> Alien.broadcast Alien.SaveSettings
                |> Ports.toBrain
                |> returnWithModel model

        SaveSources ->
            let
                updateEnabledSourceIdsOnTracks =
                    model.sources.collection
                        |> Sources.enabledSourceIds
                        |> Tracks.SetEnabledSourceIds
                        |> TracksMsg
                        |> update

                ( updatedModel, updatedCmd ) =
                    updateEnabledSourceIdsOnTracks model
            in
            updatedModel
                |> UserData.encodedSources
                |> Alien.broadcast Alien.SaveSources
                |> Ports.toBrain
                |> returnWithModel updatedModel
                |> addCommand updatedCmd

        SaveTracks ->
            model
                |> UserData.encodedTracks
                |> Alien.broadcast Alien.SaveTracks
                |> Ports.toBrain
                |> returnWithModel model



-- 📰


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ Ports.fromAlien alien

        -- Audio
        --------
        , Ports.activeQueueItemEnded (QueueMsg << always Queue.Shift)
        , Ports.setAudioDuration SetAudioDuration
        , Ports.setAudioHasStalled SetAudioHasStalled
        , Ports.setAudioIsLoading SetAudioIsLoading
        , Ports.setAudioIsPlaying SetAudioIsPlaying

        --
        , Browser.Events.onResize
            (\w h ->
                ( w, h )
                    |> ResizedWindow
                    |> Debouncer.provideInput
                    |> Debounce
            )
        , Time.every (60 * 1000) SetCurrentTime
        ]


alien : Alien.Event -> Msg
alien event =
    case event.error of
        Nothing ->
            translateAlienData event

        Just err ->
            translateAlienError event err


translateAlienData : Alien.Event -> Msg
translateAlienData event =
    case Alien.tagFromString event.tag of
        Just Alien.AddTracks ->
            TracksMsg (Tracks.Add event.data)

        Just Alien.AuthMethod ->
            -- My brain told me which auth method we're using,
            -- so we can tell the user in the UI.
            case Authentication.decodeMethod event.data of
                Just method ->
                    AuthenticationMsg (Authentication.SignedIn method)

                Nothing ->
                    Bypass

        Just Alien.FinishedProcessingSources ->
            SourcesMsg Sources.FinishedProcessing

        Just Alien.HideLoadingScreen ->
            Core.ToggleLoadingScreen Off

        Just Alien.LoadEnclosedUserData ->
            LoadEnclosedUserData event.data

        Just Alien.LoadHypaethralUserData ->
            LoadHypaethralUserData event.data

        Just Alien.NotAuthenticated ->
            -- There's not to do in this case.
            -- (ie. the case when we're not authenticated at the start)
            BackdropMsg Backdrop.Default

        Just Alien.RemoveTracksByPath ->
            TracksMsg (Tracks.RemoveByPaths event.data)

        Just Alien.ReportProcessingError ->
            case Json.Decode.decodeValue (Json.Decode.dict Json.Decode.string) event.data of
                Ok dict ->
                    ShowNotification
                        (Notifications.errorWithCode
                            ("Could not process the _"
                                ++ Dict.fetch "sourceName" "" dict
                                ++ "_ source. I got the following response from the source:"
                            )
                            (Dict.fetch "error" "missingError" dict)
                            []
                        )

                Err _ ->
                    ShowNotification
                        (Notifications.error "Could not decode processing error")

        Just Alien.SearchTracks ->
            TracksMsg (Tracks.SetSearchResults event.data)

        Just Alien.UpdateSourceData ->
            SourcesMsg (Sources.UpdateSourceData event.data)

        _ ->
            Bypass


translateAlienError : Alien.Event -> String -> Msg
translateAlienError event err =
    case Alien.tagFromString event.tag of
        Just tag ->
            err
                |> Notifications.stickyError
                |> ShowNotification

        Nothing ->
            Bypass



-- 🗺


view : Model -> Browser.Document Msg
view model =
    { title = "Diffuse"
    , body = [ toUnstyled (body model) ]
    }


body : Model -> Html Msg
body model =
    section
        (if Maybe.isJust model.contextMenu then
            [ onClick HideContextMenu ]

         else if Maybe.isJust model.equalizer.activeKnob then
            [ (EqualizerMsg << Equalizer.AdjustKnob)
                |> Pointer.onMove
                |> Html.Styled.Attributes.fromUnstyled
            , (EqualizerMsg << Equalizer.DeactivateKnob)
                |> Pointer.onUp
                |> Html.Styled.Attributes.fromUnstyled
            ]

         else
            []
        )
        [ Css.Global.global globalCss

        -----------------------------------------
        -- Backdrop
        -----------------------------------------
        , model.backdrop
            |> Lazy.lazy Backdrop.view
            |> Html.map BackdropMsg

        -----------------------------------------
        -- Context Menu
        -----------------------------------------
        , model.contextMenu
            |> Lazy.lazy UI.ContextMenu.view

        -----------------------------------------
        -- Notifications
        -----------------------------------------
        , model.notifications
            |> Lazy.lazy UI.Notifications.view

        -----------------------------------------
        -- Overlay
        -----------------------------------------
        , model.contextMenu
            |> Lazy.lazy overlay

        -----------------------------------------
        -- Content
        -----------------------------------------
        , case ( model.isLoading, model.authentication ) of
            ( True, _ ) ->
                content [ loadingAnimation ]

            ( False, Authentication.Authenticated _ ) ->
                content (defaultScreen model)

            ( False, _ ) ->
                model.authentication
                    |> Authentication.view
                    |> Html.map AuthenticationMsg
                    |> List.singleton
                    |> content
        ]


defaultScreen : Model -> List (Html Msg)
defaultScreen model =
    [ Lazy.lazy
        (Navigation.global
            [ ( Page.Index, "Tracks" )
            , ( Page.Sources UI.Sources.Page.Index, "Sources" )
            , ( Page.Settings UI.Settings.Page.Index, "Settings" )
            ]
        )
        model.page

    -----------------------------------------
    -- Main
    -----------------------------------------
    , UI.Kit.vessel
        [ model
            |> Tracks.view
            |> Html.map TracksMsg

        -- Pages
        --------
        , case model.page of
            Page.Equalizer ->
                Html.map EqualizerMsg (Equalizer.view model.equalizer)

            Page.Index ->
                nothing

            Page.Queue _ ->
                nothing

            Page.Settings subPage ->
                Settings.view subPage model

            Page.Sources subPage ->
                model.sources
                    |> Lazy.lazy2 Sources.view subPage
                    |> Html.map SourcesMsg
        ]

    -----------------------------------------
    -- Controls
    -----------------------------------------
    , UI.Console.view
        model.queue.activeItem
        model.queue.repeat
        model.queue.shuffle
        model.audioHasStalled
        model.audioIsLoading
        model.audioIsPlaying
    ]



-- 🗺  ░░  BITS


content : List (Html msg) -> Html msg
content =
    chunk
        [ T.flex
        , T.flex_column
        , T.items_center
        , T.justify_center
        , T.min_vh_100
        , T.ph3
        , T.relative
        , T.z_1
        ]


loadingAnimation : Html msg
loadingAnimation =
    Html.map never (Html.fromUnstyled UI.Svg.Elements.loading)


overlay : Maybe (ContextMenu Msg) -> Html Msg
overlay maybeContextMenu =
    brick
        [ css overlayStyles ]
        [ T.absolute
        , T.absolute__fill
        , T.z_999

        --
        , ifThenElse (Maybe.isJust maybeContextMenu) T.o_100 T.o_0
        ]
        []



-- 🖼  ░░  GLOBAL


globalCss : List Css.Global.Snippet
globalCss =
    [ -----------------------------------------
      -- Body
      -----------------------------------------
      Css.Global.body
        [ Css.color (Color.toElmCssColor UI.Kit.colors.text)
        , Css.fontFamilies UI.Kit.defaultFontFamilies
        , Css.textRendering Css.optimizeLegibility

        -- Font smoothing
        -----------------
        , Css.property "-webkit-font-smoothing" "antialiased"
        , Css.property "-moz-osx-font-smoothing" "grayscale"
        , Css.property "font-smoothing" "antialiased"
        ]

    -----------------------------------------
    -- Placeholders
    -----------------------------------------
    , Css.Global.selector "::-webkit-input-placeholder" placeholderStyles
    , Css.Global.selector "::-moz-placeholder" placeholderStyles
    , Css.Global.selector ":-ms-input-placeholder" placeholderStyles
    , Css.Global.selector ":-moz-placeholder" placeholderStyles
    , Css.Global.selector "::placeholder" placeholderStyles

    -----------------------------------------
    -- Bits & Pieces
    -----------------------------------------
    , Css.Global.selector ".lh-0" [ Css.lineHeight Css.zero ]
    , Css.Global.selector ".pointer-events-none" [ Css.pointerEvents Css.none ]
    ]


placeholderStyles : List Css.Style
placeholderStyles =
    [ Css.color (Css.rgb 0 0 0)
    , Css.opacity (Css.num 0.2)
    ]



-- 🖼  ░░  OTHER


overlayStyles : List Css.Style
overlayStyles =
    [ Css.backgroundColor (Css.rgba 0 0 0 0.25)
    , Css.pointerEvents Css.none

    --
    , Css.Transitions.transition
        [ Css.Transitions.opacity3 1000 0 Css.Transitions.ease ]
    ]
