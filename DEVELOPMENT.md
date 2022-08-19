# Development/Releasing of this Project

## Development

You can use CocoaPods or Swift Package Manager.

**Reminder:** Please see the
[CONTRIBUTING.md](https://github.com/google/gtm-session-fetcher/blob/main/CONTRIBUTING.md)
file for how to contribute to this project.

## Swift Package Manager

*  `open Package.swift` or double click `Package.swift` in Finder.
*  Xcode will open the project
   *  The _GTMSessionFetcher-Package_ scheme seems generally the simplest to
      build everything and run tests.
   *  Choose a target platform by selecting the run destination along with the
      scheme

## CocoaPods

Install
*  CocoaPods 1.10.0 (or later)
*  [CocoaPods generate](https://github.com/square/cocoapods-generate) - This is
    not part of the _core_ cocoapods install.

Generate an Xcode project from the podspec:

```
pod gen GTMSessionFetcher.podspec --local-sources=./ --auto-open --platforms=ios
```

Note: Set the `--platforms` option to `macos`, `tvos`, or `watchos` to
develop/test for those platforms.

---

## Releasing

To update the version number and push a release:

1.  Examine what has changed; determine the appropriate new version number.

1.  Update the version number.

    Run the `update_version.py` script to update the appropriate files with the
    new version number, by passing in the new version (must be in X.Y.Z format).

    ```sh
    $ ./update_version.py 1.3.1
    ```

    Submit the changes to the repo.

1.  Create a release on Github.

    Top left of the [project's release page](https://github.com/google/gtm-session-fetcher/releases)
    is _Draft a new release_.

    The tag should be vX.Y.Z where the version number X.Y.Z _exactly_ matches
    the one you provided to the `update_version.py` script. (GTMSessionFetcher
    has a `v` prefix on its tags.)

    For the description call out any major changes in the release. Usually the
    _Generate release notes_ button in the toolbar is a good starting point and
    just updating as need for more/less detail (dropping comments about CI,
    updating the version number, etc.).

1.  Publish the CocoaPod.

    1.  Do a final sanity check on the podspec file:

        ```sh
        $ pod spec lint GTMSessionFetcher.podspec
        ```

        If you used the update script above, this should pass without problems.

    1.  Publish the pod:

        ```sh
        $ pod trunk push GTMSessionFetcher.podspec
        ```
