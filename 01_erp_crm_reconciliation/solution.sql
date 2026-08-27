-- Кейс: сверка заказов между ERP и CRM
-- Период проверки: последние 60 дней


-- 1. Определяем актуальные версии заказов в обеих системах

WITH erp_latest AS (
    SELECT
        order_id,
        customer_id,
        order_date,
        order_amount,
        updated_at
    FROM (
        SELECT
            e.order_id,
            e.customer_id,
            e.order_date,
            e.order_amount,
            e.updated_at,
            ROW_NUMBER() OVER (
                PARTITION BY e.order_id
                ORDER BY e.updated_at DESC
            ) AS rn
        FROM erp_orders e
        WHERE NOT EXISTS (
            SELECT 1
            FROM excluded_orders x
            WHERE x.order_id = e.order_id
        )
    ) ranked
    WHERE rn = 1
),

crm_latest AS (
    SELECT
        order_id,
        customer_id,
        order_date,
        order_amount,
        updated_at
    FROM (
        SELECT
            c.order_id,
            c.customer_id,
            c.order_date,
            c.order_amount,
            c.updated_at,
            ROW_NUMBER() OVER (
                PARTITION BY c.order_id
                ORDER BY c.updated_at DESC
            ) AS rn
        FROM crm_orders c
        WHERE NOT EXISTS (
            SELECT 1
            FROM excluded_orders x
            WHERE x.order_id = c.order_id
        )
    ) ranked
    WHERE rn = 1
),

-- 2. Формируем единый список найденных расхождений

issues AS (

    -- Есть в ERP, но отсутствует в CRM
    SELECT
        e.order_id,
        e.customer_id,
        e.order_amount AS erp_amount,
        NULL AS crm_amount,
        NULL AS amount_difference,
        NULL AS amount_difference_pct,
        'missing_in_crm' AS issue_type
    FROM erp_latest e
    LEFT JOIN crm_latest c
        ON e.order_id = c.order_id
    WHERE c.order_id IS NULL
      AND e.order_date >= CURRENT_DATE - INTERVAL 60 DAY

    UNION ALL

    -- Есть в CRM, но отсутствует в ERP
    SELECT
        c.order_id,
        c.customer_id,
        NULL AS erp_amount,
        c.order_amount AS crm_amount,
        NULL AS amount_difference,
        NULL AS amount_difference_pct,
        'missing_in_erp' AS issue_type
    FROM crm_latest c
    LEFT JOIN erp_latest e
        ON c.order_id = e.order_id
    WHERE e.order_id IS NULL
      AND c.order_date >= CURRENT_DATE - INTERVAL 60 DAY

    UNION ALL

    -- Заказ есть в обеих системах, но отличается клиент
    SELECT
        e.order_id,
        e.customer_id,
        e.order_amount AS erp_amount,
        c.order_amount AS crm_amount,
        c.order_amount - e.order_amount AS amount_difference,
        CASE
            WHEN e.order_amount = 0 THEN NULL
            ELSE ABS(c.order_amount - e.order_amount)
                 / ABS(e.order_amount)
        END AS amount_difference_pct,
        'customer_mismatch' AS issue_type
    FROM erp_latest e
    JOIN crm_latest c
        ON e.order_id = c.order_id
    WHERE (
            e.order_date >= CURRENT_DATE - INTERVAL 60 DAY
            OR c.order_date >= CURRENT_DATE - INTERVAL 60 DAY
          )
      AND e.customer_id <> c.customer_id

    UNION ALL

    -- Заказ есть в обеих системах, но сумма отличается более чем на 2%
    SELECT
        e.order_id,
        e.customer_id,
        e.order_amount AS erp_amount,
        c.order_amount AS crm_amount,
        c.order_amount - e.order_amount AS amount_difference,
        CASE
            WHEN e.order_amount = 0 THEN NULL
            ELSE ABS(c.order_amount - e.order_amount)
                 / ABS(e.order_amount)
        END AS amount_difference_pct,
        'amount_mismatch' AS issue_type
    FROM erp_latest e
    JOIN crm_latest c
        ON e.order_id = c.order_id
    WHERE (
            e.order_date >= CURRENT_DATE - INTERVAL 60 DAY
            OR c.order_date >= CURRENT_DATE - INTERVAL 60 DAY
          )
      AND (
            (e.order_amount = 0 AND c.order_amount <> 0)
            OR
            (
                e.order_amount <> 0
                AND ABS(c.order_amount - e.order_amount)
                    / ABS(e.order_amount) > 0.02
            )
          )
)

-- 3. Добавляем информацию о клиенте

SELECT
    i.order_id,
    i.customer_id,
    c.customer_name,
    c.segment,
    i.erp_amount,
    i.crm_amount,
    i.amount_difference,
    i.amount_difference_pct,
    i.issue_type
FROM issues i
LEFT JOIN customers c
    ON i.customer_id = c.customer_id
ORDER BY
    i.issue_type,
    i.order_id;
