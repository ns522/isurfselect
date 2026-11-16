import type { Metadata } from "next";
import Link from "next/link";
import { DEVICE_PRICE_LABEL } from "@/lib/product";

export const metadata: Metadata = {
  title: "Checkout canceled",
};

export default function CanceledPage() {
  return (
    <main id="main" className="mx-auto flex w-full max-w-xl flex-1 flex-col justify-center px-5 py-24">
      <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">Checkout</p>
      <h1 className="mt-3 text-4xl font-semibold tracking-tight">No payment was made.</h1>
      <p className="mt-4 text-lg leading-8 text-muted">
        The device is still {DEVICE_PRICE_LABEL}, with US shipping included.
      </p>
      <Link
        href="/#buy"
        className="mt-8 inline-flex h-12 w-fit items-center justify-center rounded-full bg-nautique px-6 text-sm font-semibold text-white"
      >
        Return to the device
      </Link>
    </main>
  );
}
