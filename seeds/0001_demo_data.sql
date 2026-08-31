-- Seed a couple of users and posts for local development.
INSERT OR IGNORE INTO users (email, full_name) VALUES
    ('ada@example.com', 'Ada Lovelace'),
    ('alan@example.com', 'Alan Turing');

INSERT INTO posts (user_id, title, body, published)
SELECT id, 'Hello from dbauto', 'Seeded post body.', 1
FROM users
WHERE email = 'ada@example.com';
