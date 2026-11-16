import { NextResponse } from "next/server";
import type Stripe from "stripe";
import { getStripe } from "@/lib/stripe";

function logSession(eventType: string, session: Stripe.Checkout.Session, fulfilled: boolean) {
  console.info(
    JSON.stringify({
      source: "isurfselect-webhook",
      event: eventType,
      sessionId: session.id,
      paymentStatus: session.payment_status,
      amountTotal: session.amount_total,
      currency: session.currency,
      fulfilled,
    }),
  );
}

export async function POST(request: Request) {
  const stripe = getStripe();
  const secret = process.env.STRIPE_WEBHOOK_SECRET?.trim();
  if (!stripe || !secret) {
    return NextResponse.json({ error: "Webhook is not configured." }, { status: 500 });
  }

  const signature = request.headers.get("stripe-signature");
  if (!signature) {
    return NextResponse.json({ error: "Missing Stripe signature." }, { status: 400 });
  }

  const payload = await request.text();
  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(payload, signature, secret);
  } catch (error) {
    console.error(
      "webhook signature failed",
      error instanceof Error ? error.message : "unknown",
    );
    return NextResponse.json({ error: "Invalid Stripe signature." }, { status: 400 });
  }

  if (
    event.type !== "checkout.session.completed" &&
    event.type !== "checkout.session.async_payment_succeeded" &&
    event.type !== "checkout.session.async_payment_failed"
  ) {
    return NextResponse.json({ received: true });
  }

  const session = event.data.object;
  if (session.object !== "checkout.session") {
    return NextResponse.json({ received: true });
  }

  if (event.type === "checkout.session.async_payment_failed") {
    logSession(event.type, session, false);
    return NextResponse.json({ received: true });
  }

  logSession(event.type, session, session.payment_status !== "unpaid");
  return NextResponse.json({ received: true });
}
