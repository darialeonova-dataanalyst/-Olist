COPY ( 
    -- Шаг 1: Готовим и очищаем данные по заказам
    WITH orders AS ( 
        SELECT 
            order_id, 
            order_status, 
            -- Переводим текст в формат даты со временем (TIMESTAMP)
            CAST(order_purchase_timestamp AS TIMESTAMP) AS order_purchase_timestamp, 
            -- Переводим текст в формат чистой даты (DATE) для расчета задержки
            CAST(order_delivered_customer_date AS DATE) AS actual_delivery_date, 
            CAST(order_estimated_delivery_date AS DATE) AS estimated_delivery_date 
        FROM read_csv_auto('/Users/daria/Downloads/archive/olist_orders_dataset.csv', header = true) 
    ), 
    
    -- Шаг 2: Боремся с дубликатами отзывов к одному заказу
    reviews_ranked AS ( 
        SELECT 
            review_id, 
            order_id, 
            -- Переводим текстовую оценку в целое число для математических расчетов
            CAST(review_score AS INTEGER) AS review_score, 
            CAST(review_creation_date AS TIMESTAMP) AS review_creation_date, 
            CAST(review_answer_timestamp AS TIMESTAMP) AS review_answer_timestamp, 
            -- Нумеруем строки для каждого заказа (PARTITION BY order_id)
            -- Сначала берем самые свежие ответы (по дате ответа и создания), пустые значения двигаем в конец
            ROW_NUMBER() OVER ( 
                PARTITION BY order_id 
                ORDER BY CAST(review_answer_timestamp AS TIMESTAMP) DESC NULLS LAST, 
                         CAST(review_creation_date AS TIMESTAMP) DESC NULLS LAST, 
                         review_id DESC 
            ) AS review_rank 
        FROM read_csv_auto('/Users/daria/Downloads/archive/olist_order_reviews_dataset.csv', header = true) 
    ), 
    
    -- Шаг 3: Оставляем только по одному самому актуальному отзыву на заказ
    latest_reviews AS ( 
        SELECT 
            review_id, 
            order_id, 
            review_score, 
            review_creation_date, 
            review_answer_timestamp 
        FROM reviews_ranked 
        WHERE review_rank = 1 -- Фильтр: убираем дубли, оставляя строго первую (лучшую) строчку
    ), 
    
    -- Шаг 4: Склеиваем очищенные заказы и отзывы в единую витрину
    base AS ( 
        SELECT 
            o.order_id, 
            o.order_purchase_timestamp, 
            o.actual_delivery_date, 
            o.estimated_delivery_date, 
            r.review_id, 
            r.review_score, 
            r.review_creation_date, 
            r.review_answer_timestamp, 
            -- Считаем разницу в днях между фактической и обещанной датой доставки.
            -- Если результат > 0, значит доставка опоздала на это количество дней.
            date_diff('day', o.estimated_delivery_date, o.actual_delivery_date) AS delay_days 
        FROM orders o 
        -- INNER JOIN оставляет только те заказы, по которым покупатели оставили отзыв
        INNER JOIN latest_reviews r USING (order_id)
    )
    
    -- Шаг 5: Выводим финальный собранный результат
    SELECT * FROM base

-- Указываем путь на Mac, куда сохранить файл, включаем заголовки колонок и ставим разделитель-запятую
) TO '/Users/daria/Downloads/archive/final_result.csv' (HEADER, DELIMITER ',')


-- Создаем таблицу, на которую будут ссылаться все SQL-запросы
CREATE OR REPLACE VIEW analysis AS 
SELECT 
    *,
    -- Добавляем флаг опоздания
    CASE WHEN delay_days > 0 THEN TRUE ELSE FALSE END AS is_late,
    -- Добавляем флаг низкой оценки (1 и 2)
    CASE WHEN review_score IN (1, 2) THEN TRUE ELSE FALSE END AS low_rating,
    -- Добавляем группы задержки
    CASE 
        WHEN delay_days IS NULL THEN 'Нет данных'
        WHEN delay_days <= 0 THEN 'Вовремя'
        WHEN delay_days BETWEEN 1 AND 3 THEN '1–3 дня'
        WHEN delay_days BETWEEN 4 AND 7 THEN '4–7 дней'
        WHEN delay_days >= 8 THEN '8+ дней'
    END AS delay_group
FROM read_csv_auto('/Users/daria/Downloads/archive/final_result.csv')



-- Проверка размера выборки, уникальности и пропусков
SELECT
    COUNT(*) AS rows_count,
    COUNT(DISTINCT order_id) AS unique_orders,
    COUNT(*) - COUNT(DISTINCT order_id) AS duplicate_rows,
    COUNT(*) FILTER (WHERE review_score IS NULL) AS missing_scores,
    COUNT(*) FILTER (WHERE delay_days IS NULL) AS missing_delays
FROM analysis

-- Проверка корректности бизнес-логики
SELECT
    COUNT(*) AS total_orders,
    COUNT(*) FILTER (
        WHERE is_late = TRUE AND delay_days <= 0
    ) AS inconsistent_late,
    COUNT(*) FILTER (
        WHERE low_rating = TRUE AND review_score NOT IN (1, 2)
    ) AS inconsistent_low_rating,
    COUNT(*) FILTER (
        WHERE review_score NOT BETWEEN 1 AND 5
    ) AS invalid_scores
FROM analysis

-- Влияние задержки на оценку
SELECT
    delay_group,
    COUNT(*) AS orders_count,
    ROUND(AVG(review_score), 2) AS avg_review_score,
    ROUND(AVG(CASE WHEN low_rating THEN 1 ELSE 0 END) * 100, 2) AS low_rating_pct,
    ROUND(AVG(CASE WHEN is_late THEN 1 ELSE 0 END) * 100, 2) AS late_pct
FROM analysis
GROUP BY delay_group
ORDER BY
    CASE delay_group
        WHEN 'Вовремя' THEN 1
        WHEN '1–3 дня' THEN 2
        WHEN '4–7 дней' THEN 3
        WHEN '8+ дней' THEN 4
        ELSE 5
    END
    
  -- Распределение оценок внутри групп доставки
    SELECT
    CASE
        WHEN is_late THEN 'С опозданием'
        ELSE 'Вовремя / раньше срока'
    END AS delivery_status,
    review_score,
    COUNT(*) AS orders_count,
    ROUND(
        100.0 * COUNT(*) /
        SUM(COUNT(*)) OVER (
            PARTITION BY is_late
        ),
        2
    ) AS pct_within_group
FROM analysis
GROUP BY is_late, review_score
ORDER BY is_late, review_score

-- Оценка общего масштаба проблемы
SELECT
    COUNT(*) AS total_orders,
    SUM(CASE WHEN is_late THEN 1 ELSE 0 END) AS late_orders,
    SUM(CASE WHEN low_rating THEN 1 ELSE 0 END) AS low_rating_orders,
    SUM(
        CASE
            WHEN is_late AND low_rating THEN 1
            ELSE 0
        END
    ) AS late_and_low_rating_orders,
    ROUND(
        100.0 * SUM(
            CASE WHEN is_late AND low_rating THEN 1 ELSE 0 END
        ) / NULLIF(COUNT(*), 0),
        2
    ) AS pct_all_orders_late_and_low_rated
FROM analysis
