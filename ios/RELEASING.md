# Releasing the iOS app

`release-ios` builds the app on every pull request without signing it. On a
commit of `main` that passed `test`, it archives with cloud signing and uploads
the build to TestFlight for the internal testers (spec 10 §5.6). Xcode creates
the distribution certificate and the profiles in the cloud with the App Store
Connect API key. The archive is signed with one development certificate,
exported once: without it, Xcode creates a certificate on every run until the
account reaches its limit.

A build installed from a Mac is `ios/app/run-device.sh`'s job, not this one.

## Once

1. **The identifiers.** Make the App IDs and the App Group of
   [ios.md §3.1](../docs/spec/frontends/ios.md#31-identifiers) under your team, if
   `run-device.sh` has not already done so. Write them to
   `~/.config/tsync/ios-identifiers`, which stays out of the repository:

   ```sh
   export TSYNC_TEAM_ID=…
   export TSYNC_APP_ID=…
   export TSYNC_APP_GROUP=group.…
   ```

2. **The app record.** <https://appstoreconnect.apple.com/apps> → **+** → **New
   App**: platform iOS, name tsync, bundle ID `$TSYNC_APP_ID`, any SKU.

3. **The internal testers.** In the app's **TestFlight** tab, make an internal
   group with **Automatic distribution** on, and add the testers. Internal
   testers need no review.

4. **The API key.** <https://appstoreconnect.apple.com/access/integrations/api>
   → **Team Keys** → **+**, role **Admin**: cloud-managed distribution
   certificates need it, where the notarization key of `macos/RELEASING.md` is a
   Developer. Download `AuthKey_<KEYID>.p8` (once only) and note the **Issuer
   ID** above the list.

5. **The development certificate.** In Xcode, **Settings** → **Accounts** →
   the team → **Manage Certificates…** → **+** → **Apple Development**, unless
   this Mac already has one. In Keychain Access, under **My Certificates**,
   right-click **Apple Development: …** → **Export**, as a `.p12` with a
   password. The certificate lasts a year; when it is renewed, run step 6
   again.

6. **The secrets.**

   ```sh
   bash scripts/setup_ios_signing.sh AuthKey_<KEYID>.p8 <issuer-uuid> <development.p12>
   ```

   It asks for the `.p12`'s password, and sets `IOS_ASC_KEY_P8`,
   `IOS_ASC_KEY_ID`, `IOS_ASC_ISSUER_ID`, `IOS_TEAM_ID`, `IOS_APP_ID`,
   `IOS_APP_GROUP`, `IOS_DEV_CERT_P12`, `IOS_DEV_CERT_PASSWORD`, and
   `IOS_EXPORT_COMPLIANCE_CODE` once the identifiers file exports
   `TSYNC_EXPORT_COMPLIANCE_CODE`.

Then run `release-ios` from the Actions tab on `main` (`workflow_dispatch`) to
see the first upload through. Before a branch reaches `main`, pushing it to
`testflight` uploads it the same way:

```sh
git push origin <branch>:testflight
```

## Each build

- `CFBundleVersion` is the run number; `MARKETING_VERSION` in
  `ios/app/project.yml` is the version testers see.
- The extension pushes through APNs production (`TSYNC_APS_ENVIRONMENT`), so a
  TestFlight build registers production tokens with the server.
- Without an export compliance code, the build declares nothing about
  encryption, so App Store Connect holds it under **Missing Compliance** until
  the question is answered in the TestFlight tab. The code comes from the app's
  **App Encryption Documentation** in App Store Connect, once Apple approves it;
  with it in the identifiers file and step 6 run again, every build declares
  it.
