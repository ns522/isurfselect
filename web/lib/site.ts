function httpsOrigin(host: string) {
  return `https://${host.replace(/^https?:\/\//, "").replace(/\/$/, "")}`;
}

export function siteOrigin() {
  const configured = process.env.NEXT_PUBLIC_SITE_URL?.trim();
  if (configured) {
    return configured.replace(/\/$/, "");
  }

  const production = process.env.VERCEL_PROJECT_PRODUCTION_URL?.trim();
  if (process.env.VERCEL_ENV === "production" && production) {
    return httpsOrigin(production);
  }

  const vercel = process.env.VERCEL_URL?.trim();
  if (vercel) {
    return httpsOrigin(vercel);
  }

  return "http://localhost:3000";
}
