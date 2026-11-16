import { Suspense } from "react";
import type { Metadata } from "next";
import Link from "next/link";
import { OrderReceipt } from "./receipt";

export const metadata: Metadata = {
  title: "Order received",
};

export default function SuccessPage({
  searchParams,
}: {
  searchParams: Promise<{ session_id?: string | string[] }>;
}) {
  return (
    <main id="main" className="mx-auto flex w-full max-w-xl flex-1 flex-col justify-center px-5 py-24">
      <p className="text-sm font-semibold tracking-[0.16em] text-nautique uppercase">Order</p>
      <h1 className="mt-3 text-4xl font-semibold tracking-tight">Thanks for your order.</h1>
      <p className="mt-4 text-lg leading-8 text-muted">
        We’ll ship the iSurfSelect module to the address from checkout once Stripe
        confirms the payment. The receipt arrives by email.
      </p>
      <Suspense fallback={<p className="mt-6 text-muted">Checking the payment…</p>}>
        <OrderReceipt searchParams={searchParams} />
      </Suspense>
      <Link
        href="/"
        className="mt-8 inline-flex h-12 w-fit items-center justify-center rounded-full bg-nautique px-6 text-sm font-semibold text-white"
      >
        Back to iSurfSelect
      </Link>
    </main>
  );
}
