# iriz — Distribution checklist

## Identity and ownership

- Confirm the legal publisher name and copyright owner.
- Confirm the public product domain.
- Create monitored support and privacy contact addresses.
- Confirm the final app name and trademark availability.

## Website

- Confirm `https://lafayette-consulting.us/iriz/` and all absolute Open Graph URLs after deployment.
- Verify `robots.txt` and `sitemap.xml` under the `/iriz/` path.
- Verify the deployed Home, Download, Privacy, Support and Press Kit pages.
- Verify the Download page and its direct release asset URL.
- Confirm the hosting provider’s request-log and retention configuration.

## Privacy and legal review

- Review the Privacy Policy against the final shipping binary.
- Add the publisher identity and direct privacy contact method.
- Complete App Store privacy disclosures using the final distribution configuration.
- Review OpenAI API retention and data-control settings for the release account model.
- Obtain jurisdiction-specific review for microphone and meeting-audio features.
- Add any required in-app privacy-policy link before App Store submission.

## Product and commercial decisions

- Confirm direct download, App Store, Setapp or multi-channel distribution.
- Confirm pricing, trial, licensing and update mechanism.
- Decide whether the user supplies an API key in every distribution channel.
- Confirm who pays OpenAI API usage and how that cost is explained.
- Add a real download or purchase call to action only when availability is live.

## Release engineering

- Set the final bundle identifier, version and build number.
- Sign with the release Developer ID or App Store certificate.
- Notarize and staple direct-download builds.
- Publish the signed and notarized archive to GitHub Releases with the exact asset name `iriz.zip` so the permanent direct link works.
- Validate entitlements and permission purpose strings.
- Test first launch, onboarding, permissions, pause, exclusions and uninstall cleanup on a clean Mac.
- Test Universal Binary behavior on Apple silicon and Intel if both remain supported.

## Listing and launch material

- Confirm that public listing copy links to [github.com/daviddemri26/iriz](https://github.com/daviddemri26/iriz) where appropriate.
- Capture final screenshots from the shipping build with representative fictional Actions and conversations.
- Verify that screenshots reveal no personal, customer or API information.
- Export the final 1024 × 1024 icon from approved master artwork.
- Confirm subtitle, promotional text, long description and keywords.
- Prepare release notes, a short launch announcement and reviewer guidance.
- Do not claim availability on a channel until that release is public.
