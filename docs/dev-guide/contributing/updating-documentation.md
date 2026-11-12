<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Updating Documentation
The documentation is written in [Markdown](https://www.markdownguide.org/){target="_blank"}, this website is generated based on this *Markdown* content using [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/){target="_blank"} and the documentation versioning is done with [mike](https://github.com/jimporter/mike){target="_blank"}.

This website is hosted on [GitHub Pages](https://pages.github.com/){target="_blank"} based on the [`gh-pages` branch](https://github.com/k2s-project/k2s/tree/gh-pages){target="_blank"} (i.e. the default *GitHub Pages* branch).

## Updating based on `main` Branch
To update the current documentation based on the `main` branch: 

1. [Install Material for MkDocs](https://squidfunk.github.io/mkdocs-material/getting-started/){target="_blank"}
2. Run inside the local repo/installation folder of *K2s*:
   ```console
   mkdocs serve
   ```
3. Open [http://127.0.0.1:8000/K2s/](http://127.0.0.1:8000/K2s/){target="_blank"} in your web browser to see your local changes being applied on-the-fly
4. [Submit your changes](submitting-changes.md)
5. Wait for the automatically triggered workflow [![Build - Documentation (next)](https://github.com/k2s-project/k2s/actions/workflows/build-docs-next.yml/badge.svg)](https://github.com/k2s-project/k2s/actions/workflows/build-docs-next.yml){target="_blank"} to finish
6. :rocket: Your changes are now published to [https://k2s-project.github.io/k2s/next](https://k2s-project.github.io/k2s/next){target="_blank"}

!!! note
      Since `mkdocs serve` does not take versioning into account, the following warning will appear in the console output:
      `"GET /versions.json HTTP/1.1" code 404`<br/>
      This warning can safely be ignored. To test different documentation versions locally, see [Documentation Versioning](#documentation-versioning).

## Documentation Versioning
To provide different versions of the generated documentation (e.g. a version per release and a current one matching the contents of the `main` branch), to tool [mike](https://github.com/jimporter/mike){target="_blank"} can be utilized like described in the following:

If not done already, install *mike*:
```console
pip install mike
```

To inspect all existing documentation versions on the `gh-pages` branch, run:
```console
mike list
```

To add a new version, run:
```console
mike deploy <version> [<alias>]
```

!!! example
      To create a new version `v1.2.3` with the tag `latest`, run:
      ```console
      mike deploy v1.2.3 latest
      ```
      This will create a local commit to the `gh-pages` branch that still has to be pushed to *origin*.

      Alternatively, *mike* can also create a new version and push the changes in one call with the `-p` or `--pull` parameter:
      ```console
      mike deploy v1.2.3 latest -p
      ```
To set a default version the user is redirected to when browsing the root URL:
```console
mike set-default <version>|<alias>
```
!!! example
      To set the default version to the one with the tag `latest`, run:
      ```console
      mike set-default latest
      ```

To delete a version, run:
```console
mike delete <version>
```

To preview documentation versioning, run:
```console
mike serve
```

!!! tip
      `mike serve` is similar to `mkdocs serve`, but additionally takes versioning into account. On the other hand, *mike*'s local dev server is extremely slow compared to *mkdocs*'s built-in dev server so the recommendation is to use `mkdocs serve` for previewing changes to the documentation and `mike serve` for previewing changes to the versions.