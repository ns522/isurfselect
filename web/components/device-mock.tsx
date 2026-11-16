const readouts = [
  ["Side", "Port"],
  ["Speed", "12.1 mph"],
  ["Shape", "4"],
  ["Volume", "7"],
] as const;

const crownRows = ["Side", "Speed", "Volume", "Ballast"] as const;

export function DeviceMock() {
  return (
    <div className="grid items-end gap-6 sm:grid-cols-[minmax(0,1fr)_10.5rem]" aria-hidden="true">
      <div className="rounded-[2rem] border border-line bg-card p-4 shadow-[0_30px_80px_rgba(0,0,0,0.45)]">
        <div className="mb-4 flex items-center justify-between px-1 text-sm">
          <span className="font-semibold text-[#5ddea0]">Connected</span>
          <span className="text-muted">iPhone</span>
        </div>
        <div className="grid grid-cols-2 gap-3">
          {readouts.map(([label, value]) => (
            <div key={label} className="rounded-2xl bg-white/[0.06] px-3 py-3">
              <p className="text-xs font-semibold tracking-wide text-white/45 uppercase">
                {label}
              </p>
              <p className="mt-1 text-lg font-semibold">{value}</p>
            </div>
          ))}
        </div>
        <div className="mt-3 grid grid-cols-2 gap-3">
          <div className="rounded-2xl bg-nautique px-3 py-3 text-center font-semibold text-white">
            Port
          </div>
          <div className="rounded-2xl bg-white/[0.06] px-3 py-3 text-center font-semibold text-white/80">
            Starboard
          </div>
        </div>
      </div>

      <div className="relative">
        <div className="absolute top-10 -left-2 h-8 w-1.5 rounded-full bg-white/25" />
        <div className="rounded-[2.2rem] border border-line bg-[#0c0e13] px-4 py-5">
          <p className="text-center text-[11px] font-semibold tracking-[0.14em] text-muted uppercase">
            Apple Watch
          </p>
          <ul className="mt-4 space-y-2">
            {crownRows.map((row) => (
              <li
                key={row}
                className={
                  row === "Side"
                    ? "rounded-xl bg-nautique px-3 py-2 text-sm font-semibold text-white"
                    : "rounded-xl bg-white/[0.06] px-3 py-2 text-sm text-white/75"
                }
              >
                {row}
              </li>
            ))}
          </ul>
        </div>
        <p className="mt-3 text-center text-xs leading-5 text-muted">
          Crown stays live in Water Lock
        </p>
      </div>
    </div>
  );
}
