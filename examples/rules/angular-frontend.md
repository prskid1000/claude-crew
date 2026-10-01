---
paths:
  - "**/web-ui/**/*.ts"
  - "**/web-ui/**/*.html"
  - "**/web-ui/**/*.scss"
---

# Frontend (Angular) conventions — EXAMPLE

Example of a path-scoped rule: copy it into `.claude/rules/`, change `paths` to your web app's folder and replace the
bullets with your own conventions.

- Extend the shared base components (e.g. `EntityListComponent<T>` / `EntityCreateEditComponent<T>` / `EntityViewComponent<T>`);
  don't build one-off screens.
- Use the product's form-control id prefix (e.g. `app-`) so tests can find controls.
- No widgets on home/welcome screens; secondary actions go behind a toolbar icon that opens a dialog.
