# Releasing GTMSessionFetcher

---

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

    For the description call out any major changes in the release. Usually a
    reference to the pull request and a short description is sufficient.

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
