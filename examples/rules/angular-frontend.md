---
paths:
  - "**/<web-app>/**/*.ts"
  - "**/<web-app>/**/*.html"
  - "**/<web-app>/**/*.scss"
---

# Frontend (Angular) conventions — EXAMPLE

Example of a path-scoped rule: copy it into `.claude/rules/`, change `paths` to your web app's folder and replace the
bullets with your own conventions.

- Extend the shared base components (e.g. `<YourListBase><T>` / `<YourFormBase><T>`);
  don't build one-off screens.
- Use the product's form-control id prefix (e.g. `app-`) so tests can find controls.
- Reuse the shared dialog component for confirmations instead of building one per screen.
