# Who uses kinhin

A short, hand-picked list of companies and projects that run their CI on kinhin. It appears on the website.

[← Back to README](../README.md)

## Add your project

Open a pull request against `main` that adds one line to the `contributors` list in
[`website/.vitepress/sponsors.ts`](https://github.com/RabinApps/kinhin/blob/main/website/.vitepress/sponsors.ts):

```ts
{ sponsor: null, project: { name: "Your Project", url: "https://your-project.example", blurb: "What you build with kinhin." } },
```

- `name`: your project or company name.
- `url`: your own site.
- `blurb`: one short sentence about how you use kinhin.

A maintainer checks the link and the wording, then merges. The list updates with the next site build.

Want your logo shown instead? See [Support & sponsors](support.md#become-a-sponsor).
