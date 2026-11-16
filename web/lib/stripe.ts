import Stripe from "stripe";

let stripe: Stripe | null = null;
let stripeKey: string | null = null;

export function checkoutConfigured() {
  return Boolean(process.env.STRIPE_SECRET_KEY?.trim());
}

export function getStripe() {
  const key = process.env.STRIPE_SECRET_KEY?.trim();
  if (!key) {
    return null;
  }

  if (stripe && stripeKey === key) {
    return stripe;
  }

  stripe = new Stripe(key, {
    apiVersion: "2026-09-30.endive",
  });
  stripeKey = key;
  return stripe;
}
