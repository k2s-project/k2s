<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# K2s Intellectual Property Policy

K2s follows the intellectual-property requirements in [section 11 of the CNCF Charter](https://github.com/cncf/foundation/blob/main/charter.md#11-ip-policy) and the [CNCF Allowlist License Policy](https://github.com/cncf/foundation/blob/main/policies-guidance/allowed-third-party-license-policy.md#cncf-allowlist-license-policy).

## K2s Code and Documentation

- K2s code and configuration accepted under this policy are made available under the Apache License, Version 2.0. The repository's controlling license text is in [LICENSE](LICENSE).
- K2s documentation accepted under this policy is received and made available under the Creative Commons Attribution 4.0 International License.
- K2s-owned code and configuration previously made available under MIT have been relicensed under Apache-2.0 as part of the project's donation. Do not remove or replace third-party files, notices, or SPDX identifiers when modifying a file.
- Existing K2s documentation retains its declared SPDX license until its separate CC-BY-4.0 migration is complete.
- The Apache License does not grant rights to K2s or third-party trademarks. Trademark and logo ownership or transfer obligations are handled by the relevant rightsholders and project governance, not by this repository policy.

## Contributions

All new code contributions must:

1. Be submitted under the Apache License, Version 2.0.
2. Include a Developer Certificate of Origin sign-off on every commit. Use `git commit -s` to add the required `Signed-off-by` trailer.
3. Include only material the contributor is entitled to submit, including any required employer authorization.

The project may require a CNCF-approved Contributor License Agreement in addition to these requirements if project governance adopts one. A CLA does not replace the required DCO sign-off or Apache-2.0 inbound license.

## Third-Party Components

Apache-2.0 third-party dependencies may be used without additional license approval. A non-Apache-2.0 third-party component is allowed only when all of the following CNCF allowlist criteria are met:

1. It is fully licenseable under an approved CNCF allowlist license, including a permitted combination with Apache-2.0.
2. It is either unmodified in a designated third-party location or retrieved from its upstream source or package repository during installation or build.
3. It is either part of the applicable language standard library, or has substantial independent use: it was created on GitHub at least 12 months ago and has at least 10 stars or 10 forks.

Before adding a non-Apache-2.0 component, record its name, version, upstream source, SPDX license identifier, repository location or retrieval mechanism, and the evidence for its allowlist eligibility. Preserve all upstream license, copyright, and attribution notices.

Components that do not meet every allowlist criterion require a license exception approved through the [CNCF license exception process](https://github.com/cncf/foundation/issues/new?template=license-exception-request.yaml) before inclusion.
