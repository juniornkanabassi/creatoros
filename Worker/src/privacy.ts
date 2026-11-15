const STYLE = `<style>
:root{color-scheme:dark}
body{background:#111214;color:#e6e6e6;font:16px/1.6 -apple-system,system-ui,sans-serif;margin:0;padding:32px 20px}
main{max-width:640px;margin:0 auto}
h1{font-size:1.5rem}a{color:#8ab4ff}
</style>`;

export const page = (title: string, bodyHtml: string, status = 200) =>
  new Response(
    `<!doctype html><html lang="en-GB"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>${STYLE}</head><body><main>${bodyHtml}</main></body></html>`,
    { status, headers: { "content-type": "text/html; charset=utf-8" } },
  );

export const privacy = () =>
  page(
    "Privacy policy",
    `<h1>Privacy policy</h1>
<p>This is a single-user app by Junior Nkana Bassi. It shows his own social channel numbers on his own devices.</p>
<p>It uses YouTube API Services, so the <a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a> apply. Google's data handling is described in the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>.</p>
<p>The app reads channel statistics and YouTube Analytics figures only, using read-only permissions. It cannot change anything on the channel.</p>
<p>The data stays in this Worker and on his own devices. It is never shared or sold.</p>
<p>Disconnecting in the app revokes Google's access and deletes the stored data at once. Access can also be removed at <a href="https://myaccount.google.com/permissions">myaccount.google.com/permissions</a>. After that, the data is deleted within 30 days.</p>`,
  );
