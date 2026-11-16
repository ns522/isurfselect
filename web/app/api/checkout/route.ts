import { NextResponse } from "next/server";
import type Stripe from "stripe";
import {
  DEVICE_PRICE_CENTS,
  INTEGRATION_IDENTIFIER,
  PRODUCT_METADATA_KEY,
  PRODUCT_NAME,
} from "@/lib/product";
import { siteOrigin } from "@/lib/site";
import { getStripe } from "@/lib/stripe";

export async function POST() {
  const stripe = getStripe();
  if (!stripe) {
    return new NextResponse("Checkout is not configured.", {
      status: 503,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }

  const origin = siteOrigin();
  const priceId = process.env.STRIPE_PRICE_ID?.trim();
  const lineItem: Stripe.Checkout.SessionCreateParams.LineItem = priceId
    ? { price: priceId, quantity: 1 }
    : {
        quantity: 1,
        price_data: {
          currency: "usd",
          unit_amount: DEVICE_PRICE_CENTS,
          product_data: {
            name: PRODUCT_NAME,
            description:
              "Nautique Surf Select 3.0 control module for iPhone and Apple Watch. US shipping included.",
          },
        },
      };

  try {
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      integration_identifier: INTEGRATION_IDENTIFIER,
      phone_number_collection: { enabled: true },
      shipping_address_collection: { allowed_countries: ["US"] },
      shipping_options: [
        {
          shipping_rate_data: {
            type: "fixed_amount",
            display_name: "Shipping included",
            fixed_amount: { amount: 0, currency: "usd" },
          },
        },
      ],
      line_items: [lineItem],
      metadata: { product: PRODUCT_METADATA_KEY },
      success_url: `${origin}/order/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/order/canceled`,
    });

    if (!session.url) {
      return new NextResponse("Checkout did not return a payment page.", {
        status: 502,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    return NextResponse.redirect(session.url, 303);
  } catch (error) {
    console.error(
      "checkout session failed",
      error instanceof Error ? error.message : "unknown",
    );
    return new NextResponse("Checkout could not start. Try again in a moment.", {
      status: 502,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }
}
