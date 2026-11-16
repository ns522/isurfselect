import { Suspense } from "react";
import { BuyButton, BuyButtonFallback } from "@/components/buy-button";
import { DeviceMock } from "@/components/device-mock";
import { DEVICE_PRICE_LABEL } from "@/lib/product";

const controls = [
  ["Wave side", "Switch the wave to port or starboard."],
  ["Surf speed", "Set the speed the wave is built around."],
  ["Wave shape", "Move the shape from the phone while you ride."],
  ["Ballast", "Shift 50 to 400 pounds, and stop the pumps."],
  ["Volume", "Master volume, plus each stereo zone on its own."],
  ["Stereo", "See the current song and skip tracks."],
] as const;

const steps = [
  [
    "01",
    "Mount it in the locker",
    "The module goes in the starboard rear locker, next to the transom antenna.",
  ],
  [
    "02",
    "Join Surf Select",
    "It runs beside the factory Surf Select 3.0 module, and it also runs with that module unplugged.",
  ],
  [
    "03",
    "Open the app",
    "The iPhone and the Apple Watch each find iSurfSelect over Bluetooth.",
  ],
] as const;

const included = [
  "The iSurfSelect module",
  "iPhone app",
  "Apple Watch app",
  "US shipping",
] as const;

const faqs = [
  [
    "Which boats does it fit?",
    "Nautique boats with Surf Select 3.0, part 200169. The module works with the factory module connected, and it keeps Surf Select active with that module unplugged.",
  ],
  [
    "Does the watch need the phone nearby?",
    "The watch and the iPhone each connect to the module over Bluetooth. Either one can run the boat on its own.",
  ],
  [
    "What happens when Water Lock is on?",
    "Water Lock turns the watch screen off. The Digital Crown still moves through side, speed, volume, the stereo zone, track, and ballast.",
  ],
  [
    "How do firmware updates work?",
    "The iPhone sends an update to the module over Bluetooth. The module stays off Wi-Fi.",
  ],
  [
    "What does the $499 include?",
    "The device, the iPhone and Apple Watch apps, and shipping to a US address. Checkout collects email, phone, and that address.",
  ],
] as const;

function BuySlot() {
  return (
    <Suspense fallback={<BuyButtonFallback />}>
      <BuyButton />
    </Suspense>
  );
}

export default function HomePage() {
  return (
    <main id="main">
      <section className="relative overflow-hidden">
        <div
          className="pointer-events-none absolute inset-0"
          style={{
            background:
              "radial-gradient(ellipse 55% 45% at 78% 18%, rgba(237,28,36,0.22), transparent 62%)",
          }}
        />
        <div className="relative mx-auto grid max-w-6xl items-center gap-14 px-5 py-16 lg:grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)] lg:py-24">
          <div>
            <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">
              Nautique Surf Select 3.0
            </p>
            <h1 className="mt-4 max-w-xl text-5xl font-semibold tracking-tight text-balance sm:text-6xl">
              Control the surf from your wrist.
            </h1>
            <p className="mt-6 max-w-xl text-lg leading-8 text-muted">
              iSurfSelect installs in the boat and lets your iPhone and Apple
              Watch set the wave, shift ballast, and run the stereo.
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-4">
              <BuySlot />
              <a
                href="#buy"
                className="inline-flex h-12 items-center justify-center rounded-full border border-line px-5 text-sm font-semibold text-foreground transition hover:border-white/30"
              >
                {DEVICE_PRICE_LABEL}, shipping included
              </a>
            </div>
          </div>
          <DeviceMock />
        </div>
      </section>

      <section id="controls" className="border-t border-line">
        <div className="mx-auto max-w-6xl px-5 py-20">
          <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">
            Controls
          </p>
          <h2 className="mt-3 max-w-2xl text-3xl font-semibold tracking-tight sm:text-4xl">
            The same ride commands on the phone and the watch.
          </h2>
          <dl className="mt-10 grid gap-px overflow-hidden rounded-3xl border border-line bg-line sm:grid-cols-2 lg:grid-cols-3">
            {controls.map(([title, detail]) => (
              <div key={title} className="bg-background px-5 py-6">
                <dt className="text-lg font-semibold">{title}</dt>
                <dd className="mt-2 text-sm leading-6 text-muted">{detail}</dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      <section className="border-t border-line bg-card">
        <div className="mx-auto grid max-w-6xl gap-12 px-5 py-20 lg:grid-cols-2">
          <div>
            <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">
              In the water
            </p>
            <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
              Water Lock blanks the screen. The crown still drives the boat.
            </h2>
            <p className="mt-5 text-lg leading-8 text-muted">
              Turn the Digital Crown to move through side, speed, volume, the
              stereo zone, track, and ballast. A second turn sends the change.
              While the ballast pumps are running, the crown can stop them on
              the first turn.
            </p>
          </div>
          <div>
            <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">
              On the phone
            </p>
            <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
              Full controls, plus firmware updates.
            </h2>
            <p className="mt-5 text-lg leading-8 text-muted">
              The iPhone shows live side, speed, shape, volume, and the song,
              then sends the same commands as the watch. Updates travel from
              the phone to the module over Bluetooth.
            </p>
          </div>
        </div>
      </section>

      <section id="install" className="border-t border-line">
        <div className="mx-auto max-w-6xl px-5 py-20">
          <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">
            Install
          </p>
          <h2 className="mt-3 max-w-2xl text-3xl font-semibold tracking-tight sm:text-4xl">
            One module in the rear locker.
          </h2>
          <ol className="mt-10 grid gap-6 lg:grid-cols-3">
            {steps.map(([number, title, detail]) => (
              <li key={number} className="rounded-3xl border border-line bg-card p-6">
                <p className="font-mono text-sm text-nautique">{number}</p>
                <h3 className="mt-4 text-xl font-semibold">{title}</h3>
                <p className="mt-3 text-sm leading-6 text-muted">{detail}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      <section id="buy" className="border-t border-line">
        <div className="mx-auto grid max-w-6xl gap-10 px-5 py-20 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] lg:items-center">
          <div className="rounded-[2rem] border border-line bg-card p-8">
            <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">
              The device
            </p>
            <p className="mt-4 text-6xl font-semibold tracking-tight">{DEVICE_PRICE_LABEL}</p>
            <p className="mt-3 text-muted">One-time purchase. US shipping included.</p>
            <ul className="mt-8 space-y-3 text-sm">
              {included.map((item) => (
                <li key={item} className="flex items-center gap-3">
                  <span className="h-1.5 w-1.5 rounded-full bg-nautique" aria-hidden="true" />
                  {item}
                </li>
              ))}
            </ul>
            <div className="mt-8">
              <BuySlot />
            </div>
          </div>
          <div>
            <h2 className="text-3xl font-semibold tracking-tight sm:text-4xl">
              Built for Surf Select 3.0, part 200169.
            </h2>
            <p className="mt-5 text-lg leading-8 text-muted">
              Checkout takes a US shipping address, a phone number, and an email.
              Stripe handles the card. This site stores the order in Stripe until
              it ships.
            </p>
            <dl className="mt-8 divide-y divide-line border-y border-line">
              {[
                ["Boat", "Nautique with Surf Select 3.0"],
                ["Part", "200169"],
                ["Apps", "iPhone and Apple Watch"],
                ["Link", "Bluetooth, each device on its own"],
              ].map(([label, value]) => (
                <div key={label} className="flex items-baseline justify-between gap-6 py-3">
                  <dt className="text-sm text-muted">{label}</dt>
                  <dd className="text-right text-sm font-medium">{value}</dd>
                </div>
              ))}
            </dl>
          </div>
        </div>
      </section>

      <section className="border-t border-line" aria-labelledby="faq-heading">
        <div className="mx-auto max-w-3xl px-5 py-20">
          <h2 id="faq-heading" className="text-3xl font-semibold tracking-tight">
            Questions
          </h2>
          <div className="mt-8 border-t border-line">
            {faqs.map(([question, answer]) => (
              <details key={question} className="group border-b border-line py-4">
                <summary className="cursor-pointer list-none text-base font-semibold">
                  <span className="flex items-center justify-between gap-4">
                    {question}
                    <span className="text-nautique transition group-open:rotate-45" aria-hidden="true">
                      +
                    </span>
                  </span>
                </summary>
                <p className="mt-3 max-w-2xl text-sm leading-6 text-muted">{answer}</p>
              </details>
            ))}
          </div>
        </div>
      </section>
    </main>
  );
}
