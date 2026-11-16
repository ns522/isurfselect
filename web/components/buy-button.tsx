import { connection } from "next/server";
import { DEVICE_PRICE_LABEL } from "@/lib/product";
import { checkoutConfigured } from "@/lib/stripe";

export function BuyButtonFallback() {
  return (
    <div className="h-12 w-44 rounded-full bg-white/10" aria-hidden="true" />
  );
}

export async function BuyButton() {
  await connection();

  if (!checkoutConfigured()) {
    return (
      <p className="max-w-sm text-sm leading-6 text-muted">
        Purchases turn on when a Stripe restricted key is added to this site.
      </p>
    );
  }

  return (
    <form action="/api/checkout" method="POST">
      <button
        type="submit"
        className="inline-flex h-12 items-center justify-center rounded-full bg-nautique px-6 text-base font-semibold text-white transition hover:brightness-110"
      >
        Buy for {DEVICE_PRICE_LABEL}
      </button>
    </form>
  );
}
