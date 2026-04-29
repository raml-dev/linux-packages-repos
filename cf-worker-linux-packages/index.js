/**
 * Copyright 2026-present raml-dev
 * SPDX-License-Identifier: MIT
 */

/**
 * Cloudflare Worker catch-all function
 * Serves APT, RPM, and Arch package repository content from an R2 bucket.
 */

// ---------------------------------------------------------------------------
// MIME types — APT, RPM, and Arch clients are not strict, but serve correct
// types so that browsers and CDN layers don't do anything unexpected.
// ---------------------------------------------------------------------------
const MIME = {
  // Debian / APT
  ".deb": "application/vnd.debian.binary-package",
  ".udeb": "application/vnd.debian.binary-package",

  // RPM
  ".rpm": "application/x-rpm",

  // Arch Linux
  ".zst": "application/zstd",
  ".xz": "application/x-xz",
  ".sig": "application/pgp-signature",

  // Repository metadata
  ".gz": "application/gzip",
  ".bz2": "application/x-bzip2",
  ".xml": "application/xml",
  ".asc": "application/pgp-signature",
};

// R2 does not always store a Content-Type when objects are uploaded without
// one (e.g. via `wrangler r2 object put` without --content-type). This map
// covers well-known extensionless APT/RPM/Arch metadata filenames.
const MIME_BY_FILENAME = {
  // APT
  InRelease: "text/plain; charset=utf-8",
  Release: "text/plain; charset=utf-8",
  Packages: "text/plain; charset=utf-8",
  Sources: "text/plain; charset=utf-8",
  Contents: "text/plain; charset=utf-8",

  // RPM
  "repomd.xml": "application/xml",
  "repomd.xml.asc": "application/pgp-signature",
  "repomd.xml.key": "application/pgp-keys",
};

// ---------------------------------------------------------------------------
// Known repo roots — requests outside these prefixes get a 404 immediately,
// preventing any accidental traversal or probing of unrelated bucket keys.
// ---------------------------------------------------------------------------
const VALID_PREFIXES = ["apt/", "rpm/", "arch/"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Derive a Content-Type for a given R2 object + key path.
 * Priority: R2-stored metadata → filename map → extension map → fallback.
 */
function contentType(object, key) {
  const stored = object.httpMetadata?.contentType;
  if (stored && stored !== "application/octet-stream") return stored;

  const filename = key.split("/").pop() ?? "";

  if (MIME_BY_FILENAME[filename]) return MIME_BY_FILENAME[filename];

  const dot = filename.lastIndexOf(".");
  if (dot !== -1) {
    const ext = filename.slice(dot);
    if (MIME[ext]) return MIME[ext];
  }

  return "application/octet-stream";
}

/**
 * Build the response headers shared between GET and HEAD.
 */
function buildHeaders(object, key) {
  const headers = new Headers();

  headers.set("Content-Type", contentType(object, key));
  headers.set("ETag", object.httpEtag);

  if (object.size !== undefined) {
    headers.set("Content-Length", String(object.size));
  }

  if (object.uploaded) {
    headers.set("Last-Modified", object.uploaded.toUTCString());
  }

  headers.set("Cache-Control", cacheControl(key));
  headers.set("X-Content-Type-Options", "nosniff");

  return headers;
}

/**
 * Cache-Control policy:
 * - Immutable packages (.deb, .rpm, .pkg.tar.zst): long TTL.
 * - Mutable metadata (Release, Packages, repomd.xml, .db): short TTL.
 */
function cacheControl(key) {
  const immutableExtensions = [".deb", ".udeb", ".rpm", ".zst", ".xz"];
  const dot = key.lastIndexOf(".");
  if (dot !== -1 && immutableExtensions.includes(key.slice(dot))) {
    return "public, max-age=31536000, immutable";
  }
  return "public, max-age=60, stale-while-revalidate=30";
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

export default {
  async fetch(request, env) {
    // ------------------------------------------------------------------
    // 1. Method guard — APT, RPM, and Arch all use GET + HEAD only.
    // ------------------------------------------------------------------
    const method = request.method.toUpperCase();
    if (method !== "GET" && method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD" },
      });
    }

    // ------------------------------------------------------------------
    // 2. Resolve the R2 object key from the URL path.
    //    Strip the leading slash to get a clean bucket key.
    // ------------------------------------------------------------------
    const url = new URL(request.url);
    const key = url.pathname.replace(/^\//, "");

    if (!key) {
      return new Response("Not Found", { status: 404 });
    }

    // ------------------------------------------------------------------
    // 3. Prefix guard — only serve from known repo roots.
    // ------------------------------------------------------------------
    const allowed = VALID_PREFIXES.some((prefix) => key.startsWith(prefix));
    if (!allowed) {
      return new Response("Not Found", { status: 404 });
    }

    // ------------------------------------------------------------------
    // 4. Fetch from R2.
    //    Use .head() for HEAD requests to avoid streaming the body.
    // ------------------------------------------------------------------
    try {
      if (method === "HEAD") {
        const object = await env.REPO_BUCKET.head(key);
        if (!object) return new Response(null, { status: 404 });
        return new Response(null, {
          status: 200,
          headers: buildHeaders(object, key),
        });
      }

      // GET — support Range requests so large .deb/.rpm downloads can resume.
      const rangeHeader = request.headers.get("Range");

      let object;
      if (rangeHeader) {
        object = await env.REPO_BUCKET.get(key, {
          range: request.headers,
        });
      } else {
        object = await env.REPO_BUCKET.get(key);
      }

      if (!object) return new Response("Not Found", { status: 404 });

      const headers = buildHeaders(object, key);
      const status = object.range ? 206 : 200;

      if (object.range) {
        const { offset = 0, length, end } = object.range;
        const last = end ?? offset + (length ?? 0) - 1;
        headers.set("Content-Range", `bytes ${offset}-${last}/${object.size}`);
        if (length !== undefined) {
          headers.set("Content-Length", String(length));
        }
      }

      return new Response(object.body, { status, headers });

    } catch (err) {
      // Surface R2 errors as 502 so that package managers retry rather than
      // caching a 500 as a permanent failure.
      console.error(`R2 error for key "${key}":`, err);
      return new Response("Bad Gateway", { status: 502 });
    }
  },
};