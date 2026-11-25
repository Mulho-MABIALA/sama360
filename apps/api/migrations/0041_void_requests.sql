-- Demande d'annulation d'une vente par le vendeur : le propriétaire ou le gérant accepte (annule) ou refuse
ALTER TABLE sales.sales
  ADD COLUMN void_request_status varchar(10) CHECK (void_request_status IN ('pending', 'rejected')),
  ADD COLUMN void_request_reason text,
  ADD COLUMN void_requested_by uuid,
  ADD COLUMN void_requested_at timestamptz,
  ADD COLUMN void_reject_reason text;
CREATE INDEX sales_void_pending_idx ON sales.sales (business_id) WHERE void_request_status = 'pending';
