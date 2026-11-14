-- Run in Supabase SQL Editor on a NEW project. Review before execution.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 name text not null default '', mobile text not null default '',
 is_admin boolean not null default false, created_at timestamptz not null default now()
);
create table if not exists public.categories (
 id bigint generated always as identity primary key, name text unique not null
);
insert into public.categories(name) values
 ('Artificial Jewellery'),('Women''s Fashion Accessories'),('Earrings'),('Necklaces & Rings'),('Men''s Accessories'),('Imitation Jewellery'),('Rakhi Collection'),('Handmade Jewellery'),('Handicrafts Items'),('Making Materials'),('Fridge Magnets'),('Wall Hangings'),('MDF Products'),('Gifts & More')
on conflict (name) do nothing;
create table if not exists public.products (
 id bigint generated always as identity primary key,
 name text not null, category text not null, description text not null default '',
 price numeric(12,2) not null check(price>=0), stock integer not null default 0 check(stock>=0),
 active boolean not null default true, image_path text, created_at timestamptz not null default now()
);
create table if not exists public.orders (
 id bigint generated always as identity primary key,
 customer_id uuid not null references auth.users(id),
 customer_name text not null, mobile text not null, address text not null,
 total numeric(12,2) not null check(total>=0),
 utr text, status text not null default 'Pending verification' check(status in ('Pending verification','Confirmed','Packed','Shipped','Out for delivery','Delivered','Cancelled')),
 created_at timestamptz not null default now()
);
create table if not exists public.order_items (
 id bigint generated always as identity primary key, order_id bigint not null references public.orders(id) on delete cascade,
 product_id bigint references public.products(id) on delete set null,
 product_name text not null, unit_price numeric(12,2) not null, quantity integer not null check(quantity>0)
);
create table if not exists public.shop_settings (
 key text primary key, value text not null default ''
);
insert into public.shop_settings(key,value) values ('upi_id',''),('upi_name','RM Creation'),('upi_enabled','0'),('whatsapp',''),('whatsapp_enabled','0') on conflict do nothing;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and is_admin=true);
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;
create or replace function public.new_profile() returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into public.profiles(id,name,mobile) values(new.id,coalesce(new.raw_user_meta_data->>'name',''),coalesce(new.raw_user_meta_data->>'mobile',''));
 return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.new_profile();
alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.shop_settings enable row level security;
create policy "profiles read own or admin" on public.profiles for select to authenticated using (id=(select auth.uid()) or public.is_admin());
create policy "profiles update own safe fields" on public.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()));
-- Prevent client from changing is_admin, including through profile update policy.
revoke update on public.profiles from authenticated;
grant update(name,mobile) on public.profiles to authenticated;
create policy "categories public read" on public.categories for select to anon,authenticated using(true);
create policy "categories admin manage" on public.categories for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "products public visible" on public.products for select to anon,authenticated using(active=true or public.is_admin());
create policy "products admin insert" on public.products for insert to authenticated with check(public.is_admin());
create policy "products admin update" on public.products for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "products admin delete" on public.products for delete to authenticated using(public.is_admin());
create policy "orders own or admin read" on public.orders for select to authenticated using(customer_id=(select auth.uid()) or public.is_admin());
create policy "orders admin update" on public.orders for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "order items own or admin read" on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and (o.customer_id=(select auth.uid()) or public.is_admin())));
create policy "settings public read safe keys" on public.shop_settings for select to anon,authenticated using(key in ('upi_id','upi_name','upi_enabled','whatsapp','whatsapp_enabled') or public.is_admin());
create policy "settings admin insert" on public.shop_settings for insert to authenticated with check(public.is_admin());
create policy "settings admin update" on public.shop_settings for update to authenticated using(public.is_admin()) with check(public.is_admin());
-- Place orders atomically, derive prices from DB, decrement stock in same transaction.
create or replace function public.place_order(p_product_id bigint,p_quantity integer,p_address text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_product public.products%rowtype; v_profile public.profiles%rowtype; v_id bigint;
begin
 if auth.uid() is null then raise exception 'Please sign in'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>100 then raise exception 'Invalid quantity'; end if;
 if length(trim(coalesce(p_address,'')))<8 or length(p_address)>500 then raise exception 'Enter a valid delivery address'; end if;
 select * into v_product from public.products where id=p_product_id and active=true for update;
 if not found or v_product.stock<p_quantity then raise exception 'Product unavailable or insufficient stock'; end if;
 select * into v_profile from public.profiles where id=auth.uid();
 if not found or length(trim(v_profile.name))=0 or v_profile.mobile !~ '^[6-9][0-9]{9}$' then raise exception 'Complete name and Indian mobile in your profile'; end if;
 insert into public.orders(customer_id,customer_name,mobile,address,total)
 values(auth.uid(),v_profile.name,v_profile.mobile,p_address,v_product.price*p_quantity) returning id into v_id;
 insert into public.order_items(order_id,product_id,product_name,unit_price,quantity)
 values(v_id,v_product.id,v_product.name,v_product.price,p_quantity);
 update public.products set stock=stock-p_quantity where id=v_product.id;
 return v_id;
end; $$;
revoke all on function public.place_order(bigint,integer,text) from public;
grant execute on function public.place_order(bigint,integer,text) to authenticated;
-- Customers can submit UTR but cannot change order status or total.
create or replace function public.submit_utr(p_order_id bigint,p_utr text)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if p_utr !~ '^[A-Za-z0-9-]{6,80}$' then raise exception 'Invalid transaction reference'; end if;
 update public.orders set utr=p_utr where id=p_order_id and customer_id=auth.uid() and status='Pending verification';
 if not found then raise exception 'Order not found or cannot be updated'; end if;
end; $$;
revoke all on function public.submit_utr(bigint,text) from public;
grant execute on function public.submit_utr(bigint,text) to authenticated;
-- Storage: public read of product images, admin-only writes.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
('product-images','product-images',true,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy "product image public read" on storage.objects for select to anon,authenticated using(bucket_id='product-images');
create policy "product image admin upload" on storage.objects for insert to authenticated with check(bucket_id='product-images' and public.is_admin());
create policy "product image admin delete" on storage.objects for delete to authenticated using(bucket_id='product-images' and public.is_admin());
