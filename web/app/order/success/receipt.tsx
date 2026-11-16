import { PRODUCT_METADATA_KEY, PRODUCT_NAME } from "@/lib/product";
import { getStripe } from "@/lib/stripe";

const SESSION_ID = /^cs_(test|live)_[A-Za-z0-9]+$/;

type Receipt =
  | { status: "pending" }
  | { status: "paid"; amount: string; email: string | null };

function formatMoney(amount: number | null, currency: string | null) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: (currency ?? "usd").toUpperCase(),
  }).format((amount ?? 0) / 100);
}

async function loadReceipt(sessionId: string): Promise<Receipt | null> {
  const stripe = getStripe();
  if (!stripe) {
    return null;
  }

  try {
    const session = await stripe.checkout.sessions.retrieve(sessionId);
    if (session.metadata?.product && session.metadata.product !== PRODUCT_METADATA_KEY) {
      return null;
    }

    if (session.payment_status === "unpaid") {
      return { status: "pending" };
    }

    return {
      status: "paid",
      amount: formatMoney(session.amount_total, session.currency),
      email: session.customer_details?.email ?? null,
    };
  } catch {
    return null;
  }
}

export async function OrderReceipt({
  searchParams,
}: {
  searchParams: Promise<{ session_id?: string | string[] }>;
}) {
  const params = await searchParams;
  const raw = params.session_id;
  const sessionId = Array.isArray(raw) ? raw[0] : raw;
  if (!sessionId || !SESSION_ID.test(sessionId)) {
    return null;
  }

  const receipt = await loadReceipt(sessionId);
  if (!receipt) {
    return null;
  }

  if (receipt.status === "pending") {
    return (
      <p className="mt-6 text-muted">
        Stripe is still confirming this payment. Shipping starts after it clears.
      </p>
    );
  }

  return (
    <p className="mt-6 text-muted">
      Paid {receipt.amount} for {PRODUCT_NAME}
      {receipt.email ? `. The receipt goes to ${receipt.email}.` : "."}
    </p>
  );
}
