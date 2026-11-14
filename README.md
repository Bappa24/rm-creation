# RM Creation — React + Supabase + Cloudflare Pages

Rebuild of the uploaded Flask storefront, preserving its blush/rose visual identity and the core flows: product catalog, category filter, product detail, email/password customer auth, checkout, manual UPI payment QR, WhatsApp, order history, admin products, admin orders and payment settings. English/Hindi selector included. This is a **new app**, not a live migration of customer data.

## 1. Supabase

1. Create a Supabase project.
2. In **SQL Editor**, run `supabase/schema.sql` (on a fresh project). The script enables RLS, storage policies and secure checkout functions.
3. In **Authentication → Providers → Email**, configure email confirmations and SMTP as appropriate. This app uses **email + password**, with a 10-digit Indian mobile number stored in profile; it is **not mobile OTP authentication**.
4. Sign up through the website. To grant yourself admin access, use the SQL Editor **after verifying your account's email**:

```sql
update public.profiles set is_admin = true
where id = (select id from auth.users where email = 'YOUR_OWN_ADMIN_EMAIL');
```

Never expose a Supabase `service_role`/secret key in browser code or `VITE_` environment variables. Only use your public publishable/anon key. Keep RLS enabled.

## 2. Run locally

Requires Node.js 20+ and npm.

```bash
npm install
cp .env.example .env
# Fill in VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in .env
npm run dev
```

## 3. Cloudflare Pages deployment

1. Push this folder to a new GitHub repository (or replace your existing Flask repository **only after backing it up**).
2. Cloudflare Dashboard → Workers & Pages → Create → Pages → Connect to Git.
3. Framework: **Vite**; build command `npm run build`; build output directory `dist`.
4. Add **VITE_SUPABASE_URL** and **VITE_SUPABASE_ANON_KEY** as build environment variables.
5. In Supabase **Authentication → URL Configuration**, set Site URL to the deployed Pages URL and add the production URL to Redirect URLs.
6. Deploy and test sign up, email confirmation, checkout, order history and admin workflows.

## 4. Existing data migration — NOT automatic

The uploaded ZIP does not contain `rm_creation.db` or the uploaded photos. Back up the **original** SQLite database and `uploads/` directory before deleting the Render instance. The new database schema is different; old customers cannot automatically log in using Flask password hashes. Plan a password-reset / re-registration flow, and map old orders to new auth user IDs. The ZIP does not include a tested historical-data import script.

## 5. Security / operational notes

- `place_order` is an atomic SQL function: locks the product, validates stock, computes the total server-side and decrements stock. Only signed-in users can call it.
- Customer order data is protected with Row Level Security. Admin status changes require an admin role. **UTR is not proof of payment**; confirm in your bank/UPI account before marking Confirmed.
- Product photos are publicly readable; uploads require admin permission. Old uploaded images are not in this ZIP.
- For production, add rate limiting, bot protection, audit logs, delivery-charge calculation, cancellation/stock-restoration policies, transactional emails, a formal privacy policy, and backup/restore procedures.
- This initial version supports **single-product checkout**, matching the uploaded Flask project. It does **not** implement a multi-product cart or CSV/Excel bulk import yet.
- Product deletion can leave unreferenced images in Storage; periodically clean these up using an admin-only process.
- Free tiers have usage quotas and can change. Cloudflare Pages is the frontend host; Supabase provides backend services.
