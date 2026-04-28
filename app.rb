#!/usr/bin/env ruby
# frozen_string_literal: true

begin
  require 'webrick'
rescue LoadError
  abort "Не вдалося підключити WEBrick. Якщо Ruby встановлено, виконайте: gem install webrick"
end

require 'cgi'
require 'erb'
require 'fileutils'
require 'thread'
require 'time'
require 'yaml'

class PostRepository
  def initialize(storage_path)
    @storage_path = storage_path
    @mutex = Mutex.new
    ensure_storage_file
  end

  def all
    load_posts.sort_by { |post| -post['id'] }
  end

  def find(id)
    load_posts.find { |post| post['id'] == id.to_i }
  end

  def create(attributes)
    @mutex.synchronize do
      posts = load_posts
      timestamp = Time.now.iso8601
      post = {
        'id' => next_id(posts),
        'title' => normalize_text(attributes.fetch(:title)).strip,
        'body' => normalize_text(attributes.fetch(:body)).strip,
        'created_at' => timestamp,
        'updated_at' => timestamp
      }

      posts << post
      save_posts(posts)
      post
    end
  end

  def update(id, attributes)
    @mutex.synchronize do
      posts = load_posts
      post = posts.find { |item| item['id'] == id.to_i }
      return nil unless post

      post['title'] = normalize_text(attributes.fetch(:title)).strip
      post['body'] = normalize_text(attributes.fetch(:body)).strip
      post['updated_at'] = Time.now.iso8601

      save_posts(posts)
      post
    end
  end

  def delete(id)
    @mutex.synchronize do
      posts = load_posts
      filtered_posts = posts.reject { |item| item['id'] == id.to_i }
      return false if filtered_posts.length == posts.length

      save_posts(filtered_posts)
      true
    end
  end

  private

  def ensure_storage_file
    FileUtils.mkdir_p(File.dirname(@storage_path))
    return if File.exist?(@storage_path)

    File.write(@storage_path, [].to_yaml, encoding: 'UTF-8')
  end

  def load_posts
    data = parse_yaml(File.read(@storage_path, encoding: 'UTF-8'))
    Array(data).map { |post| normalize_post(post) }
  rescue Psych::SyntaxError
    []
  end

  def save_posts(posts)
    File.write(@storage_path, posts.to_yaml, encoding: 'UTF-8')
  end

  def next_id(posts)
    posts.map { |post| post['id'].to_i }.max.to_i + 1
  end

  def parse_yaml(content)
    YAML.safe_load(content, permitted_classes: [], permitted_symbols: [], aliases: false)
  rescue ArgumentError
    YAML.safe_load(content, [], [], false)
  end

  def normalize_post(post)
    {
      'id' => post['id'].to_i,
      'title' => normalize_text(post['title']),
      'body' => normalize_text(post['body']),
      'created_at' => post['created_at'].to_s,
      'updated_at' => post['updated_at'].to_s
    }
  end

  def normalize_text(value)
    text = value.to_s.dup
    text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::ASCII_8BIT
    text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
  end
end

class ViewContext
  def initialize(assigns = {})
    assigns.each do |key, value|
      instance_variable_set("@#{key}", value)
    end
  end

  def get_binding
    binding
  end

  def h(value)
    CGI.escapeHTML(value.to_s)
  end

  def format_timestamp(value)
    return '' if value.to_s.empty?

    Time.parse(value.to_s).strftime('%d.%m.%Y %H:%M')
  rescue ArgumentError
    value.to_s
  end

  def preview(text, limit = 180)
    value = text.to_s.strip.gsub(/\s+/, ' ')
    return value if value.length <= limit

    "#{value[0, limit].rstrip}..."
  end

  def paragraphs(text)
    safe_text = h(text).gsub(/\r\n?/, "\n")
    safe_text.split(/\n{2,}/).map do |paragraph|
      "<p>#{paragraph.gsub("\n", '<br>')}</p>"
    end.join("\n")
  end
end

class BlogServlet < WEBrick::HTTPServlet::AbstractServlet
  LAYOUT_TEMPLATE = <<~ERB
    <!DOCTYPE html>
    <html lang="uk">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title><%= h(@title || "Ruby CRUD Blog") %></title>
      <style>
        :root {
          --bg: #f5efe4;
          --bg-accent: #efe3cf;
          --card: #fffaf2;
          --ink: #2f241f;
          --muted: #6f6159;
          --line: #dcc9b1;
          --primary: #b85c38;
          --primary-dark: #8f4428;
          --danger: #9f2f2f;
          --shadow: 0 22px 50px rgba(77, 48, 28, 0.12);
        }

        * {
          box-sizing: border-box;
        }

        body {
          margin: 0;
          font-family: Georgia, "Times New Roman", serif;
          color: var(--ink);
          background:
            radial-gradient(circle at top left, rgba(184, 92, 56, 0.15), transparent 30%),
            linear-gradient(180deg, var(--bg-accent), var(--bg));
          min-height: 100vh;
        }

        a {
          color: inherit;
          text-decoration: none;
        }

        .page {
          width: min(960px, calc(100% - 32px));
          margin: 0 auto;
          padding: 32px 0 56px;
        }

        .hero {
          display: flex;
          justify-content: space-between;
          gap: 24px;
          align-items: flex-start;
          margin-bottom: 24px;
        }

        .eyebrow {
          margin: 0 0 8px;
          font-size: 0.85rem;
          letter-spacing: 0.16em;
          text-transform: uppercase;
          color: var(--primary);
        }

        h1, h2, h3 {
          margin: 0;
          line-height: 1.1;
        }

        h1 {
          font-size: clamp(2.1rem, 4vw, 3.4rem);
          max-width: 10ch;
        }

        .subtitle {
          margin: 12px 0 0;
          max-width: 52ch;
          color: var(--muted);
          line-height: 1.6;
        }

        .toolbar,
        .form-actions,
        .post-card__actions,
        .post-detail__actions {
          display: flex;
          flex-wrap: wrap;
          gap: 12px;
          align-items: center;
        }

        .button {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          border: 1px solid transparent;
          border-radius: 999px;
          padding: 11px 18px;
          background: var(--primary);
          color: #fff7ef;
          font-size: 0.95rem;
          cursor: pointer;
          transition: transform 0.15s ease, background 0.15s ease;
        }

        .button:hover {
          background: var(--primary-dark);
          transform: translateY(-1px);
        }

        .button.secondary {
          background: transparent;
          color: var(--ink);
          border-color: var(--line);
        }

        .button.ghost {
          padding: 0;
          border: 0;
          background: transparent;
          color: var(--primary);
        }

        .button.ghost:hover {
          background: transparent;
          color: var(--primary-dark);
          transform: none;
        }

        .button.danger {
          color: var(--danger);
        }

        .card {
          background: rgba(255, 250, 242, 0.88);
          border: 1px solid rgba(220, 201, 177, 0.7);
          border-radius: 28px;
          box-shadow: var(--shadow);
          padding: 28px;
          backdrop-filter: blur(8px);
        }

        .section-heading {
          display: flex;
          justify-content: space-between;
          gap: 16px;
          align-items: end;
          margin-bottom: 24px;
        }

        .section-heading p,
        .post-card p,
        .post-meta,
        .alert li,
        .message-card p {
          color: var(--muted);
          line-height: 1.6;
        }

        .section-heading p {
          margin: 8px 0 0;
        }

        .posts-grid {
          display: grid;
          gap: 18px;
        }

        .post-card {
          padding: 22px;
          border-radius: 22px;
          border: 1px solid var(--line);
          background: linear-gradient(180deg, rgba(255, 255, 255, 0.78), rgba(245, 235, 220, 0.55));
        }

        .post-card h3 {
          margin-top: 10px;
          font-size: 1.4rem;
        }

        .post-card__meta,
        .post-detail__meta {
          display: flex;
          flex-wrap: wrap;
          gap: 10px 18px;
          font-size: 0.9rem;
          color: var(--muted);
        }

        .post-detail h2 {
          font-size: clamp(1.9rem, 3vw, 2.8rem);
          margin: 18px 0 14px;
        }

        .post-detail__body {
          font-size: 1.06rem;
          line-height: 1.8;
          margin-bottom: 26px;
        }

        .post-detail__body p {
          margin: 0 0 1em;
        }

        .post-form {
          display: grid;
          gap: 18px;
        }

        label {
          display: grid;
          gap: 8px;
          font-weight: 700;
        }

        input,
        textarea {
          width: 100%;
          border: 1px solid var(--line);
          border-radius: 18px;
          padding: 14px 16px;
          font: inherit;
          color: var(--ink);
          background: rgba(255, 255, 255, 0.84);
        }

        textarea {
          resize: vertical;
          min-height: 220px;
        }

        input:focus,
        textarea:focus {
          outline: 2px solid rgba(184, 92, 56, 0.22);
          border-color: var(--primary);
        }

        .alert {
          border-radius: 18px;
          padding: 16px 18px;
          border: 1px solid rgba(159, 47, 47, 0.18);
          background: rgba(159, 47, 47, 0.08);
          margin-bottom: 20px;
        }

        .alert strong {
          display: block;
          margin-bottom: 8px;
        }

        .alert ul {
          margin: 0;
          padding-left: 18px;
        }

        .empty-state,
        .message-card {
          padding: 18px;
          border-radius: 22px;
          border: 1px dashed var(--line);
          background: rgba(239, 227, 207, 0.36);
        }

        .inline-form {
          margin: 0;
        }

        @media (max-width: 720px) {
          .page {
            width: min(100% - 20px, 960px);
            padding-top: 20px;
          }

          .hero,
          .section-heading {
            flex-direction: column;
            align-items: stretch;
          }

          .card {
            padding: 20px;
            border-radius: 22px;
          }
        }
      </style>
    </head>
    <body>
      <div class="page">
        <header class="hero">
          <div>
            <p class="eyebrow">Ruby CRUD Blog</p>
            <h1>Простий блог для постів</h1>
            <p class="subtitle">
              Мініпроєкт на Ruby з базовим CRUD-функціоналом: створення, перегляд, редагування та видалення записів.
            </p>
          </div>
          <nav class="toolbar">
            <a class="button secondary" href="/posts">Усі пости</a>
            <a class="button" href="/posts/new">Створити пост</a>
          </nav>
        </header>

        <main class="card">
          <%= @content %>
        </main>
      </div>
    </body>
    </html>
  ERB

  INDEX_TEMPLATE = <<~ERB
    <section class="section-heading">
      <div>
        <h2>Усі пости</h2>
        <p>
          <% if @posts.empty? %>
            Поки що тут порожньо. Додайте перший запис і блог оживе.
          <% else %>
            У блозі зараз <%= @posts.length %> пост(ів).
          <% end %>
        </p>
      </div>
    </section>

    <% if @posts.empty? %>
      <section class="empty-state">
        <h3>Ще немає жодного поста</h3>
        <p>Почніть з короткої нотатки, новини або особистого допису.</p>
        <a class="button" href="/posts/new">Написати перший пост</a>
      </section>
    <% else %>
      <section class="posts-grid">
        <% @posts.each do |post| %>
          <article class="post-card">
            <div class="post-card__meta">
              <span>Пост #<%= post['id'] %></span>
              <span>Оновлено: <%= format_timestamp(post['updated_at']) %></span>
            </div>
            <h3>
              <a href="/posts/<%= post['id'] %>"><%= h(post['title']) %></a>
            </h3>
            <p><%= h(preview(post['body'])) %></p>
            <div class="post-card__actions">
              <a class="button secondary" href="/posts/<%= post['id'] %>">Читати</a>
              <a class="button secondary" href="/posts/<%= post['id'] %>/edit">Редагувати</a>
              <form class="inline-form" action="/posts/<%= post['id'] %>/delete" method="post" onsubmit="return confirm('Видалити цей пост?');">
                <button class="button ghost danger" type="submit">Видалити</button>
              </form>
            </div>
          </article>
        <% end %>
      </section>
    <% end %>
  ERB

  FORM_TEMPLATE = <<~ERB
    <section class="section-heading">
      <div>
        <h2><%= h(@heading) %></h2>
        <p><%= h(@description) %></p>
      </div>
    </section>

    <% unless @errors.empty? %>
      <section class="alert">
        <strong>Будь ласка, виправте:</strong>
        <ul>
          <% @errors.each do |error| %>
            <li><%= h(error) %></li>
          <% end %>
        </ul>
      </section>
    <% end %>

    <form class="post-form" action="<%= h(@action) %>" method="post">
      <label>
        Заголовок
        <input type="text" name="title" value="<%= h(@post['title']) %>" maxlength="120" required>
      </label>

      <label>
        Текст поста
        <textarea name="body" rows="12" required><%= h(@post['body']) %></textarea>
      </label>

      <div class="form-actions">
        <button class="button" type="submit"><%= h(@submit_label) %></button>
        <a class="button secondary" href="<%= h(@cancel_path) %>">Скасувати</a>
      </div>
    </form>
  ERB

  SHOW_TEMPLATE = <<~ERB
    <article class="post-detail">
      <div class="post-detail__meta">
        <span>Створено: <%= format_timestamp(@post['created_at']) %></span>
        <span>Оновлено: <%= format_timestamp(@post['updated_at']) %></span>
      </div>

      <h2><%= h(@post['title']) %></h2>

      <div class="post-detail__body">
        <%= paragraphs(@post['body']) %>
      </div>

      <div class="post-detail__actions">
        <a class="button" href="/posts/<%= @post['id'] %>/edit">Редагувати</a>
        <a class="button secondary" href="/posts">Назад до списку</a>
        <form class="inline-form" action="/posts/<%= @post['id'] %>/delete" method="post" onsubmit="return confirm('Видалити цей пост?');">
          <button class="button ghost danger" type="submit">Видалити пост</button>
        </form>
      </div>
    </article>
  ERB

  MESSAGE_TEMPLATE = <<~ERB
    <section class="message-card">
      <h2><%= h(@heading) %></h2>
      <p><%= h(@message) %></p>
      <a class="button" href="/posts">Повернутися до постів</a>
    </section>
  ERB

  TEMPLATES = {
    'layout' => LAYOUT_TEMPLATE,
    'index' => INDEX_TEMPLATE,
    'form' => FORM_TEMPLATE,
    'show' => SHOW_TEMPLATE,
    'message' => MESSAGE_TEMPLATE
  }.freeze

  def initialize(server, options = {})
    super(server)
    @repository = options.fetch(:repository)
  end

  def do_GET(req, res)
    handle_request(req, res)
  end

  def do_POST(req, res)
    handle_request(req, res)
  end

  private

  def handle_request(req, res)
    if req.request_method == 'GET'
      handle_get(req, res)
    elsif req.request_method == 'POST'
      handle_post(req, res)
    else
      render_message(
        res,
        title: 'Метод не підтримується',
        heading: 'Метод не підтримується',
        message: 'Спробуйте відкрити сторінку у браузері або надіслати форму повторно.',
        status: 405
      )
    end
  rescue StandardError => error
    warn "[#{Time.now.iso8601}] #{error.class}: #{error.message}"
    warn error.backtrace.join("\n")
    render_message(
      res,
      title: 'Помилка сервера',
      heading: 'Щось пішло не так',
      message: 'Під час обробки запиту виникла помилка. Перезапустіть сервер і спробуйте ще раз.',
      status: 500
    )
  end

  def handle_get(req, res)
    case req.path
    when '/', '/posts'
      render_page(res, 'index', title: 'Усі пости', posts: @repository.all)
    when '/posts/new'
      render_page(
        res,
        'form',
        title: 'Новий пост',
        heading: 'Створення поста',
        description: 'Заповніть заголовок і текст нового запису.',
        action: '/posts',
        submit_label: 'Створити пост',
        cancel_path: '/posts',
        post: empty_post,
        errors: []
      )
    else
      if (match = req.path.match(%r{\A/posts/(\d+)\z}))
        show_post(res, match[1].to_i)
      elsif (match = req.path.match(%r{\A/posts/(\d+)/edit\z}))
        edit_post(res, match[1].to_i)
      else
        render_message(
          res,
          title: 'Сторінку не знайдено',
          heading: '404',
          message: 'Такої сторінки немає. Можливо, її адресу було змінено.',
          status: 404
        )
      end
    end
  end

  def handle_post(req, res)
    case req.path
    when '/posts'
      create_post(req, res)
    else
      if (match = req.path.match(%r{\A/posts/(\d+)/update\z}))
        update_post(req, res, match[1].to_i)
      elsif (match = req.path.match(%r{\A/posts/(\d+)/delete\z}))
        delete_post(res, match[1].to_i)
      else
        render_message(
          res,
          title: 'Сторінку не знайдено',
          heading: '404',
          message: 'Такої дії не існує.',
          status: 404
        )
      end
    end
  end

  def create_post(req, res)
    attributes = request_attributes(req)
    errors = validate(attributes)

    if errors.empty?
      post = @repository.create(attributes)
      redirect_to(res, "/posts/#{post['id']}")
      return
    end

    render_page(
      res,
      'form',
      title: 'Новий пост',
      heading: 'Створення поста',
      description: 'Заповніть заголовок і текст нового запису.',
      action: '/posts',
      submit_label: 'Створити пост',
      cancel_path: '/posts',
      post: stringify_post(attributes),
      errors: errors,
      status: 422
    )
  end

  def show_post(res, id)
    post = @repository.find(id)
    return post_not_found(res) unless post

    render_page(res, 'show', title: post['title'], post: post)
  end

  def edit_post(res, id)
    post = @repository.find(id)
    return post_not_found(res) unless post

    render_page(
      res,
      'form',
      title: "Редагування: #{post['title']}",
      heading: 'Редагування поста',
      description: 'Оновіть текст або назву публікації.',
      action: "/posts/#{id}/update",
      submit_label: 'Зберегти зміни',
      cancel_path: "/posts/#{id}",
      post: post,
      errors: []
    )
  end

  def update_post(req, res, id)
    original_post = @repository.find(id)
    return post_not_found(res) unless original_post

    attributes = request_attributes(req)
    errors = validate(attributes)

    if errors.empty?
      @repository.update(id, attributes)
      redirect_to(res, "/posts/#{id}")
      return
    end

    render_page(
      res,
      'form',
      title: "Редагування: #{original_post['title']}",
      heading: 'Редагування поста',
      description: 'Оновіть текст або назву публікації.',
      action: "/posts/#{id}/update",
      submit_label: 'Зберегти зміни',
      cancel_path: "/posts/#{id}",
      post: original_post.merge(stringify_post(attributes)),
      errors: errors,
      status: 422
    )
  end

  def delete_post(res, id)
    @repository.delete(id)
    redirect_to(res, '/posts')
  end

  def post_not_found(res)
    render_message(
      res,
      title: 'Пост не знайдено',
      heading: 'Пост не знайдено',
      message: 'Схоже, цей запис уже видалено або його ще не було створено.',
      status: 404
    )
  end

  def request_attributes(req)
    {
      title: normalize_request_text(req.query['title']),
      body: normalize_request_text(req.query['body'])
    }
  end

  def validate(attributes)
    errors = []
    errors << 'Заголовок не може бути порожнім.' if attributes[:title].strip.empty?
    errors << 'Текст поста не може бути порожнім.' if attributes[:body].strip.empty?
    errors << 'Заголовок має містити не більше 120 символів.' if attributes[:title].strip.length > 120
    errors
  end

  def empty_post
    { 'title' => '', 'body' => '' }
  end

  def stringify_post(attributes)
    {
      'title' => attributes[:title].to_s,
      'body' => attributes[:body].to_s
    }
  end

  def normalize_request_text(value)
    text = value.to_s.dup
    text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::ASCII_8BIT
    text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
  end

  def render_page(res, template_name, locals = {})
    content = render_template(template_name, locals)
    html = render_template('layout', locals.merge(content: content))
    write_html(res, html, status: locals.fetch(:status, 200))
  end

  def render_message(res, title:, heading:, message:, status:)
    render_page(
      res,
      'message',
      title: title,
      heading: heading,
      message: message,
      status: status
    )
  end

  def render_template(template_name, locals)
    template = TEMPLATES.fetch(template_name)
    context = ViewContext.new(locals)
    ERB.new(template).result(context.get_binding)
  end

  def write_html(res, html, status:)
    res.status = status
    res['Content-Type'] = 'text/html; charset=utf-8'
    res.body = html
  end

  def redirect_to(res, path)
    res.status = 303
    res['Location'] = path
    res.body = ''
  end
end

if __FILE__ == $PROGRAM_NAME
  storage_path = File.join(__dir__, 'storage', 'posts.yml')
  repository = PostRepository.new(storage_path)

  server = WEBrick::HTTPServer.new(
    Port: 4567,
    BindAddress: '127.0.0.1',
    AccessLog: [],
    Logger: WEBrick::Log.new($stdout, WEBrick::Log::WARN)
  )

  server.mount '/', BlogServlet, repository: repository

  trap('INT') { server.shutdown }
  trap('TERM') { server.shutdown }

  puts 'Блог запущено на http://127.0.0.1:4567'
  server.start
end
