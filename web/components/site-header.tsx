import Link from "next/link";

const links = [
  ["Controls", "/#controls"],
  ["Install", "/#install"],
  ["Buy", "/#buy"],
] as const;

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-20 border-b border-line bg-background/85 backdrop-blur-md">
      <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-5 py-4">
        <Link href="/" className="text-lg font-semibold tracking-tight">
          iSurf<span className="text-nautique">Select</span>
        </Link>
        <nav aria-label="Page" className="flex items-center gap-5 text-sm text-white/70">
          {links.map(([label, href]) => (
            <Link key={href} href={href} className="transition hover:text-foreground">
              {label}
            </Link>
          ))}
        </nav>
      </div>
    </header>
  );
}
