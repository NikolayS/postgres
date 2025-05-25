-- Sample SQL file to test pg_restore object tracking
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL
);

CREATE INDEX idx_users_email ON users(email);

CREATE TABLE posts (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    title VARCHAR(200) NOT NULL,
    content TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_posts_user ON posts(user_id);

-- Insert some test data
INSERT INTO users (name, email) VALUES 
    ('John Doe', 'john@example.com'),
    ('Jane Smith', 'jane@example.com');

INSERT INTO posts (user_id, title, content) VALUES 
    (1, 'First Post', 'This is the content of the first post'),
    (2, 'Second Post', 'This is the content of the second post');

-- Create a view
CREATE VIEW user_posts AS 
SELECT u.name, u.email, p.title, p.content, p.created_at
FROM users u
JOIN posts p ON u.id = p.user_id;

-- Add a constraint
ALTER TABLE posts ADD CONSTRAINT check_title_length CHECK (LENGTH(title) > 0);