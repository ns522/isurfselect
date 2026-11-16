# iSurfSelect storefront

Marketing site for the iSurfSelect module. The device is $499, with US shipping included. Stripe Checkout takes the payment. Orders live in the Stripe Dashboard.

## Run locally

```bash
cd web
cp .env.example .env.local
npm run dev
```

Add a Stripe restricted key to `STRIPE_SECRET_KEY` before the buy button can open Checkout. `STRIPE_WEBHOOK_SECRET` is the signing secret for `POST /api/webhook`.

The webhook handles `checkout.session.completed`, `checkout.session.async_payment_succeeded`, and `checkout.session.async_payment_failed`. A paid session is acknowledged in the server log. Shipping still happens from the Stripe Dashboard.

Point the Stripe webhook endpoint at `https://<deployment>/api/webhook` after deploy, then put that endpoint’s signing secret in `STRIPE_WEBHOOK_SECRET`.
