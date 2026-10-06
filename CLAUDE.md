# Neechan: notes for Claude

## GitHub releases

The `.ipa` attached to a GitHub release is an **unsigned Debug build**. Debug is
the unrestricted app: the full board directory, nothing hidden, posting on, and
every alternate icon (`NEECHAN_RESTRICTED_BUILD: NO` in `project.yml`).

```sh
make ipa ARCHIVE_CONFIG=Debug VERSION=<version>
```

- **This is not the default.** Plain `make ipa` and
  `.github/workflows/release.yml` archive Release. Release is restricted the
  same way the App Store build is: the curated directory, the terms, no
  `AppIcon3`, and boards for adults hidden at first. Do not attach that one.
- **Rename the file before attaching.** For anything but Release, the Makefile's
  `IPA` variable adds `-appstore` to the name, so this build comes out as
  `.build/Neechan-appstore-<version>.ipa`. Attach it as `Neechan-<version>.ipa`.
- **Check the build is the unrestricted one** before attaching. Both of these
  must print `NO`:

  ```sh
  plutil -extract NeechanIsRestrictedBuild raw .build/Neechan-Debug.xcarchive/Products/Applications/Neechan.app/Info.plist
  plutil -extract NeechanIsAppStoreBuild raw .build/Neechan-Debug.xcarchive/Products/Applications/Neechan.app/Info.plist
  ```
- **It stays unsigned.** `make ipa` turns signing off for itself, and no
  certificate belongs in this repository.
