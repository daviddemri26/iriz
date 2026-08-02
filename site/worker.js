const publicPathPrefix = "/iriz";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === publicPathPrefix) {
      url.pathname = `${publicPathPrefix}/`;
      return Response.redirect(url.toString(), 308);
    }

    if (!url.pathname.startsWith(`${publicPathPrefix}/`)) {
      return fetch(request);
    }

    url.pathname = url.pathname.slice(publicPathPrefix.length) || "/";
    return env.ASSETS.fetch(new Request(url.toString(), request));
  }
};
